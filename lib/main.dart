import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shamsi_date/shamsi_date.dart';

const _fd = '۰۱۲۳۴۵۶۷۸۹', _ad = '٠١٢٣٤٥٦٧٨٩';
const purple = Color(0xFF7B2FA0);
String fa(String s) => s.replaceAllMapped(RegExp(r'[0-9]'), (m) => _fd[int.parse(m[0]!)]);
String en(String s) {
  var r = s;
  for (var i = 0; i < 10; i++) {
    r = r.replaceAll(_fd[i], '$i').replaceAll(_ad[i], '$i');
  }
  return r;
}
String norm(String s) => en(s).replaceAll('ي', 'ی').replaceAll('ك', 'ک').toLowerCase().trim();
String money(int v) {
  final neg = v < 0;
  final s = v.abs().toString(), b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return fa('${neg ? '-' : ''}$b');
}
int pInt(String s) => int.tryParse(en(s).replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
double pDbl(String s) => double.tryParse(en(s).replaceAll('٫', '.').replaceAll(',', '.')) ?? 0;
String shamsi(DateTime d) {
  final j = Jalali.fromDateTime(d);
  return fa('${j.year}/${j.month.toString().padLeft(2, '0')}/${j.day.toString().padLeft(2, '0')}');
}
int round100(double v) => (v / 100).round() * 100;
void snack(BuildContext c, String t) => ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(t)));

class Product {
  String id, name, code, barcode;
  int buy, sell, qty;
  double profit;
  String? photo;
  DateTime updated;
  List<Map<String, dynamic>> hist;
  Product({required this.id, this.name = '', this.code = '', this.barcode = '', this.buy = 0, this.sell = 0, this.qty = 0, this.profit = 20, this.photo, DateTime? updated, List<Map<String, dynamic>>? hist})
      : updated = updated ?? DateTime.now(),
        hist = hist ?? [];
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'code': code, 'barcode': barcode, 'buy': buy, 'sell': sell, 'qty': qty, 'profit': profit, 'photo': photo, 'updated': updated.toIso8601String(), 'hist': hist};
  factory Product.fromJson(Map<String, dynamic> j) => Product(
        id: j['id'], name: j['name'] ?? '', code: j['code'] ?? '', barcode: j['barcode'] ?? '',
        buy: j['buy'] ?? 0, sell: j['sell'] ?? 0, qty: j['qty'] ?? 0, profit: (j['profit'] ?? 20).toDouble(), photo: j['photo'],
        updated: DateTime.tryParse(j['updated'] ?? ''), hist: List<Map<String, dynamic>>.from((j['hist'] ?? []).map((e) => Map<String, dynamic>.from(e))));
  void record() {
    updated = DateTime.now();
    hist.add({'d': updated.toIso8601String(), 's': sell, 'b': buy});
  }
  File? get photoFile => photo == null ? null : File('${docDir.path}/photos/$photo');
  bool get low => qty <= st.low;
}

class Settings {
  String shop, phone, address, footer;
  String? logo, lastBackup;
  int low, nextNo;
  Settings({this.shop = 'فروشگاه من', this.phone = '', this.address = '', this.footer = 'با تشکر از خرید شما', this.logo, this.lastBackup, this.low = 3, this.nextNo = 1001});
  Map<String, dynamic> toJson() => {'shop': shop, 'phone': phone, 'address': address, 'footer': footer, 'logo': logo, 'lastBackup': lastBackup, 'low': low, 'nextNo': nextNo};
  factory Settings.fromJson(Map<String, dynamic> j) => Settings(shop: j['shop'] ?? '', phone: j['phone'] ?? '', address: j['address'] ?? '', footer: j['footer'] ?? '', logo: j['logo'], lastBackup: j['lastBackup'], low: j['low'] ?? 3, nextNo: j['nextNo'] ?? 1001);
}

class Invoice {
  int no, discount, paid;
  DateTime date;
  String customer, phone, pay;
  bool voided;
  List<Map<String, dynamic>> lines, pays;
  Invoice({required this.no, required this.date, this.customer = '', this.phone = '', required this.lines, this.discount = 0, this.pay = 'cash', this.paid = 0, this.voided = false, List<Map<String, dynamic>>? pays}) : pays = pays ?? [];
  int get sum => lines.fold<int>(0, (a, l) => a + (l['q'] as int) * (l['p'] as int));
  int get total => sum - discount;
  int get debt => voided ? 0 : total - paid;
  int get profit {
    var t = 0;
    for (final l in lines) {
      final b = (l['b'] ?? 0) as int;
      if (b > 0) t += ((l['p'] as int) - b) * (l['q'] as int);
    }
    return t - discount;
  }
  Map<String, dynamic> toJson() => {'no': no, 'date': date.toIso8601String(), 'customer': customer, 'phone': phone, 'lines': lines, 'discount': discount, 'pay': pay, 'paid': paid, 'void': voided, 'pays': pays};
  factory Invoice.fromJson(Map<String, dynamic> j) {
    final v = Invoice(
      no: j['no'], date: DateTime.parse(j['date']), customer: j['customer'] ?? '', phone: j['phone'] ?? '', discount: j['discount'] ?? 0,
      pay: j['pay'] ?? 'cash', paid: j['paid'] ?? 0, voided: j['void'] ?? false,
      lines: List<Map<String, dynamic>>.from((j['lines'] ?? []).map((e) => Map<String, dynamic>.from(e))),
      pays: List<Map<String, dynamic>>.from((j['pays'] ?? []).map((e) => Map<String, dynamic>.from(e))),
    );
    if (j['paid'] == null) v.paid = v.total;
    return v;
  }
}

late Directory docDir;
List<Product> items = [];
List<Invoice> invoices = [];
Settings st = Settings();
File _f(String n) => File('${docDir.path}/$n');
Future<void> saveDb() => _f('products.json').writeAsString(jsonEncode(items.map((e) => e.toJson()).toList()));
Future<void> saveSt() => _f('settings.json').writeAsString(jsonEncode(st.toJson()));
Future<void> saveInv() => _f('invoices.json').writeAsString(jsonEncode(invoices.map((e) => e.toJson()).toList()));
Future<void> loadDb() async {
  docDir = await getApplicationDocumentsDirectory();
  await Directory('${docDir.path}/photos').create(recursive: true);
  items = [];
  invoices = [];
  st = Settings();
  Future<dynamic> rd(String n) async {
    final f = _f(n);
    if (await f.exists()) {
      try {
        return jsonDecode(await f.readAsString());
      } catch (_) {}
    }
    return null;
  }
  final a = await rd('products.json');
  if (a is List) items = a.map((e) => Product.fromJson(Map<String, dynamic>.from(e))).toList();
  final s = await rd('settings.json');
  if (s is Map) st = Settings.fromJson(Map<String, dynamic>.from(s));
  final v = await rd('invoices.json');
  if (v is List) invoices = v.map((e) => Invoice.fromJson(Map<String, dynamic>.from(e))).toList();
}
Product? prod(String id) => items.where((e) => e.id == id).firstOrNull;
Widget logoImg(double size) {
  final f = st.logo == null ? null : File('${docDir.path}/photos/${st.logo}');
  return (f != null && f.existsSync()) ? Image.file(f, width: size, height: size, fit: BoxFit.contain) : const SizedBox.shrink();
}
Future<ui.Image> capture(GlobalKey k) async {
  await WidgetsBinding.instance.endOfFrame;
  final ctx = k.currentContext;
  if (ctx == null) throw Exception('صفحه کامل آماده نیست؛ دوباره امتحان کنید');
  return (ctx.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: 2.5);
}
Future<void> guard(BuildContext c, Future<void> Function() f) async {
  snack(c, 'در حال آماده‌سازی…');
  try {
    await f();
  } catch (e) {
    if (c.mounted) {
      showDialog(
        context: c,
        builder: (_) => AlertDialog(
          title: const Text('خطا'),
          content: SingleChildScrollView(child: SelectableText('$e')),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('بستن'))],
        ),
      );
    }
  }
}
Future<Uint8List> pngOf(ui.Image i) async => (await i.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
Future<Uint8List> pdfOfKeys(List<GlobalKey> keys) async {
  final doc = pw.Document();
  for (final k in keys) {
    final img = await capture(k);
    final png = await pngOf(img);
    const w = 420.0;
    final h = w * img.height / img.width;
    doc.addPage(pw.Page(pageFormat: PdfPageFormat(w, h), margin: pw.EdgeInsets.zero, build: (_) => pw.Image(pw.MemoryImage(png), width: w, height: h, fit: pw.BoxFit.fill)));
  }
  return doc.save();
}
Future<void> payDialog(BuildContext c, Invoice v) async {
  final t = TextEditingController(text: fa('${v.debt}'));
  final ok = await showDialog<bool>(
    context: c,
    builder: (_) => AlertDialog(
      title: Text('ثبت پرداخت — مانده ${money(v.debt)}'),
      content: TextField(controller: t, keyboardType: TextInputType.number, autofocus: true),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('انصراف')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('ثبت')),
      ],
    ),
  );
  if (ok == true) {
    final a = pInt(t.text) > v.debt ? v.debt : pInt(t.text);
    if (a > 0) {
      v.paid += a;
      v.pays.add({'d': DateTime.now().toIso8601String(), 'a': a});
      await saveInv();
    }
  }
}
Future<String?> pickPhoto(ImageSource s) async {
  final x = await ImagePicker().pickImage(source: s, maxWidth: 900, imageQuality: 70);
  if (x == null) return null;
  final name = '${DateTime.now().millisecondsSinceEpoch}.jpg';
  await File(x.path).copy('${docDir.path}/photos/$name');
  return name;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadDb();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'لیست قیمت آسیا',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: purple,
          useMaterial3: true,
          scaffoldBackgroundColor: const Color(0xFFF6F2F9),
          appBarTheme: const AppBarTheme(backgroundColor: purple, foregroundColor: Colors.white),
        ),
        builder: (c, w) => Directionality(textDirection: TextDirection.rtl, child: w!),
        home: const Home(),
      );
}

// ---------------- Home ----------------
class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  String q = '';
  final sel = <String>{};

  List<Product> get shown {
    final k = norm(q);
    final l = items.where((p) => k.isEmpty || norm(p.name).contains(k) || p.code.contains(k) || p.barcode == k).toList();
    l.sort((a, b) => a.name.compareTo(b.name));
    return l;
  }

  Future<void> go(Widget w) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => w));
    setState(() {});
  }

  Future<void> scan() async {
    final code = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const ScanPage()));
    if (code == null || !mounted) return;
    final p = items.where((e) => e.barcode == code || (e.code.isNotEmpty && e.code == en(code))).firstOrNull;
    if (p == null) {
      snack(context, 'کالای جدید است؛ اطلاعاتش را وارد کنید');
      await go(EditPage(barcode: code));
    } else {
      showQuick(p);
    }
  }

  void showQuick(Product p) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          if (p.photoFile != null && p.photoFile!.existsSync()) Image.file(p.photoFile!, height: 160),
          const SizedBox(height: 8),
          Text(p.name, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18)),
          const SizedBox(height: 8),
          Text('${money(p.sell)} تومان', style: const TextStyle(fontSize: 34, fontWeight: FontWeight.bold)),
          Text('موجودی: ${fa('${p.qty}')}', style: TextStyle(color: p.low ? Colors.red : Colors.black87)),
          Text('آخرین تغییر قیمت: ${shamsi(p.updated)}'),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('بستن')),
          FilledButton(onPressed: () { Navigator.pop(context); go(EditPage(product: p)); }, child: const Text('ویرایش')),
        ],
      ),
    );
  }

  Future<void> bulkMenu() async {
    if (sel.isNotEmpty) {
      bulk(items.where((p) => sel.contains(p.id)).toList());
      return;
    }
    final c = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.select_all), title: const Text('همه‌ی کالاها'), onTap: () => Navigator.pop(context, 'all')),
          ListTile(leading: const Icon(Icons.checklist), title: const Text('انتخاب کالا از لیست'), onTap: () => Navigator.pop(context, 'pick')),
        ]),
      ),
    );
    if (!mounted) return;
    if (c == 'all') {
      bulk(List.of(items));
    } else if (c == 'pick') {
      final ids = await Navigator.push<Set<String>>(context, MaterialPageRoute(builder: (_) => const MultiPickPage()));
      if (ids != null && ids.isNotEmpty) bulk(items.where((p) => ids.contains(p.id)).toList());
    }
  }

  void bulk(List<Product> targets) {
    final c = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('تغییر قیمت ${fa('${targets.length}')} کالا'),
        content: TextField(controller: c, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: const InputDecoration(labelText: 'درصد افزایش (برای کاهش، منفی بنویسید)', suffixText: '٪')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('انصراف')),
          FilledButton(
            onPressed: () async {
              final pct = double.tryParse(en(c.text).replaceAll('٫', '.')) ?? 0;
              if (pct != 0) {
                for (final p in targets) {
                  if (p.buy > 0) {
                    p.buy = (p.buy * (1 + pct / 100)).round();
                    p.sell = round100(p.buy * (1 + p.profit / 100));
                  } else {
                    p.sell = round100(p.sell * (1 + pct / 100));
                  }
                  p.record();
                }
                await saveDb();
              }
              if (mounted) { Navigator.pop(context); setState(() => sel.clear()); }
            },
            child: const Text('اعمال'),
          ),
        ],
      ),
    );
  }

  Future<void> shareMenu() async {
    final targets = sel.isEmpty ? shown : items.where((p) => sel.contains(p.id)).toList();
    final c = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.text_snippet), title: const Text('ارسال به‌صورت متن'), onTap: () => Navigator.pop(context, 't')),
          ListTile(leading: const Icon(Icons.picture_as_pdf), title: const Text('لیست قیمت مرتب (تصویر / PDF)'), onTap: () => Navigator.pop(context, 'p')),
        ]),
      ),
    );
    if (!mounted) return;
    if (c == 't') {
      shareText();
    } else if (c == 'p' && targets.isNotEmpty) {
      go(PriceListPage(targets));
    }
  }

  Widget backupBanner() {
    final lb = st.lastBackup == null ? null : DateTime.tryParse(st.lastBackup!);
    final old = lb == null || DateTime.now().difference(lb).inDays >= 7;
    if (!old || (items.isEmpty && invoices.isEmpty)) return const SizedBox.shrink();
    return Card(
      color: const Color(0xFFFFF3E0),
      child: ListTile(dense: true, leading: const Icon(Icons.warning_amber, color: Colors.orange), title: Text(lb == null ? 'هنوز پشتیبان نگرفته‌اید' : 'آخرین پشتیبان ${shamsi(lb)} بود'), trailing: const Text('گرفتن'), onTap: () => go(const SettingsPage())),
    );
  }

  void shareText() {
    final targets = sel.isEmpty ? shown : items.where((p) => sel.contains(p.id)).toList();
    final t = StringBuffer('لیست قیمت ${st.shop} — ${shamsi(DateTime.now())}\n\n');
    for (final p in targets) {
      t.writeln('${p.name}: ${money(p.sell)} تومان');
    }
    Share.share(t.toString());
  }

  Color ageColor(Product p) {
    final d = DateTime.now().difference(p.updated).inDays;
    return d > 30 ? Colors.red : (d > 14 ? Colors.orange : Colors.green);
  }

  Widget stat(String t, String v, Color c) => Expanded(
        child: Card(child: Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Column(children: [
          Text(v, style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: c)),
          const SizedBox(height: 2),
          Text(t, style: const TextStyle(fontSize: 11)),
        ]))),
      );

  Widget nav(IconData i, String t, VoidCallback f) => Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: FilledButton.tonal(
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 6)),
            onPressed: f,
            child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(i), const SizedBox(height: 2), Text(t, style: const TextStyle(fontSize: 12))]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final list = shown;
    final stockVal = items.fold<int>(0, (a, p) => a + p.buy * p.qty);
    final lowCount = items.where((p) => p.low).length;
    return Scaffold(
      appBar: AppBar(
        title: Text(sel.isEmpty ? st.shop : '${fa('${sel.length}')} انتخاب'),
        leading: sel.isEmpty ? null : IconButton(icon: const Icon(Icons.close), onPressed: () => setState(sel.clear)),
        actions: [
          IconButton(tooltip: 'تغییر درصدی قیمت', icon: const Icon(Icons.trending_up), onPressed: bulkMenu),
          IconButton(tooltip: 'ارسال لیست', icon: const Icon(Icons.share), onPressed: shareMenu),
          IconButton(tooltip: 'راهنما', icon: const Icon(Icons.help_outline), onPressed: () => go(const HelpPage())),
        ],
      ),
      body: Column(children: [
        Row(children: [
          stat('تعداد کالا', fa('${items.length}'), purple),
          stat('ارزش موجودی (خرید)', money(stockVal), Colors.teal),
          stat('کم‌موجود', fa('$lowCount'), lowCount > 0 ? Colors.red : Colors.green),
        ]),
        backupBanner(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(children: [
            Row(children: [
              nav(Icons.point_of_sale, 'فروش جدید', () => go(const SalePage())),
              nav(Icons.move_to_inbox, 'ورود کالا', () => go(const StockInPage())),
              nav(Icons.receipt_long, 'فاکتورها', () => go(const InvoicesPage())),
            ]),
            const SizedBox(height: 4),
            Row(children: [
              nav(Icons.bar_chart, 'گزارش', () => go(const ReportPage())),
              nav(Icons.account_balance_wallet, 'بدهکاران', () => go(const DebtPage())),
              nav(Icons.settings, 'تنظیمات', () => go(const SettingsPage())),
            ]),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            decoration: InputDecoration(hintText: 'جست‌وجوی نام یا کد کالا', prefixIcon: const Icon(Icons.search), filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
            onChanged: (v) => setState(() => q = v),
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? const Center(child: Text('کالایی نیست. با دکمه‌ی دوربین یا + اضافه کنید'))
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 170),
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final p = list[i];
                    final days = DateTime.now().difference(p.updated).inDays;
                    final f = p.photoFile;
                    return Card(
                      child: ListTile(
                        selected: sel.contains(p.id),
                        leading: SizedBox(width: 52, height: 52, child: (f != null && f.existsSync()) ? ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.file(f, fit: BoxFit.cover)) : const Icon(Icons.inventory_2_outlined, size: 36)),
                        title: Text(p.name),
                        subtitle: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, children: [
                          Icon(Icons.circle, size: 10, color: ageColor(p)),
                          Text(days == 0 ? 'امروز' : '${fa('$days')} روز پیش'),
                          Text('موجودی: ${fa('${p.qty}')}', style: TextStyle(color: p.low ? Colors.red : null, fontWeight: p.low ? FontWeight.bold : null)),
                        ]),
                        trailing: Text(money(p.sell), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
                        onTap: () => sel.isNotEmpty ? setState(() => sel.contains(p.id) ? sel.remove(p.id) : sel.add(p.id)) : showQuick(p),
                        onLongPress: () => setState(() => sel.contains(p.id) ? sel.remove(p.id) : sel.add(p.id)),
                      ),
                    );
                  },
                ),
        ),
      ]),
      floatingActionButton: Column(mainAxisSize: MainAxisSize.min, children: [
        FloatingActionButton.small(heroTag: 'add', onPressed: () => go(const EditPage()), child: const Icon(Icons.add)),
        const SizedBox(height: 10),
        FloatingActionButton.large(heroTag: 'scan', onPressed: scan, child: const Icon(Icons.qr_code_scanner, size: 40)),
      ]),
    );
  }
}

// ---------------- Scan ----------------
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final qrKey = GlobalKey(debugLabel: 'QR');
  QRViewController? ctrl;
  bool done = false, torch = false;

  @override
  void dispose() {
    ctrl?.dispose();
    super.dispose();
  }

  void created(QRViewController c) {
    ctrl = c;
    c.scannedDataStream.listen((s) {
      final v = s.code;
      if (done || v == null || v.isEmpty) return;
      done = true;
      if (mounted) Navigator.pop(context, v);
    });
  }

  void typeCode() {
    final c = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('کد یا بارکد را تایپ کنید'),
        content: TextField(controller: c, keyboardType: TextInputType.number, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('انصراف')),
          FilledButton(
            onPressed: () {
              final t = en(c.text).trim();
              Navigator.pop(context);
              if (t.isNotEmpty) {
                done = true;
                Navigator.pop(context, t);
              }
            },
            child: const Text('تأیید'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('بارکد را داخل کادر بگیرید'), actions: [
          IconButton(
            icon: Icon(torch ? Icons.flash_on : Icons.flash_off),
            onPressed: () async {
              await ctrl?.toggleFlash();
              final f = await ctrl?.getFlashStatus();
              setState(() => torch = f ?? false);
            },
          ),
        ]),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: FilledButton.tonalIcon(onPressed: typeCode, icon: const Icon(Icons.keyboard), label: const Text('تایپ دستی کد')),
          ),
        ),
        body: QRView(
          key: qrKey,
          onQRViewCreated: created,
          overlay: QrScannerOverlayShape(borderColor: Colors.white, borderWidth: 6, cutOutWidth: 320, cutOutHeight: 180, overlayColor: const Color(0x99000000)),
        ),
      );
}

// ---------------- Edit product ----------------
class EditPage extends StatefulWidget {
  final Product? product;
  final String barcode;
  const EditPage({super.key, this.product, this.barcode = ''});
  @override
  State<EditPage> createState() => _EditPageState();
}

class _EditPageState extends State<EditPage> {
  late final nameC = TextEditingController(text: widget.product?.name ?? '');
  late final codeC = TextEditingController(text: fa(widget.product?.code ?? ''));
  late final barC = TextEditingController(text: widget.product?.barcode ?? widget.barcode);
  late final buyC = TextEditingController(text: widget.product == null || widget.product!.buy == 0 ? '' : fa('${widget.product!.buy}'));
  late final profC = TextEditingController(text: fa((widget.product?.profit ?? 20).toString().replaceAll(RegExp(r'\.0$'), '')));
  late final sellC = TextEditingController(text: widget.product == null ? '' : fa('${widget.product!.sell}'));
  late final qtyC = TextEditingController(text: fa('${widget.product?.qty ?? 0}'));
  String? photo;

  @override
  void initState() {
    super.initState();
    photo = widget.product?.photo;
  }

  void calc() {
    final buy = pInt(buyC.text);
    if (buy > 0) sellC.text = fa('${round100(buy * (1 + pDbl(profC.text) / 100))}');
  }

  Future<void> pick(ImageSource s) async {
    final n = await pickPhoto(s);
    if (n != null) setState(() => photo = n);
  }

  Future<void> scanBar() async {
    final c = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const ScanPage()));
    if (c != null) setState(() => barC.text = c);
  }

  Future<void> save() async {
    final name = nameC.text.trim();
    if (name.isEmpty) {
      snack(context, 'اسم کالا را بنویسید');
      return;
    }
    final buy = pInt(buyC.text), sell = pInt(sellC.text);
    final bc = barC.text.trim();
    final dup = bc.isEmpty ? null : items.where((e) => e.barcode == bc && e.id != widget.product?.id).firstOrNull;
    if (dup != null) {
      snack(context, 'این بارکد قبلاً برای «${dup.name}» ثبت شده');
      return;
    }
    var p = widget.product;
    final isNew = p == null;
    final changed = isNew || p.sell != sell || p.buy != buy;
    p ??= Product(id: '${DateTime.now().millisecondsSinceEpoch}');
    p..name = name..code = en(codeC.text).trim()..barcode = barC.text.trim()..buy = buy..sell = sell..qty = pInt(qtyC.text)..profit = pDbl(profC.text)..photo = photo;
    if (changed) p.record();
    if (isNew) items.add(p);
    await saveDb();
    if (mounted) Navigator.pop(context);
  }

  Future<void> del() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(title: const Text('حذف کالا؟'), actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('خیر')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('حذف')),
      ]),
    );
    if (ok == true) {
      items.remove(widget.product);
      await saveDb();
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = photo == null ? null : File('${docDir.path}/photos/$photo');
    final hist = widget.product?.hist.reversed.take(10).toList() ?? [];
    const bd = OutlineInputBorder();
    return Scaffold(
      appBar: AppBar(title: Text(widget.product == null ? 'کالای جدید' : 'ویرایش کالا'), actions: [
        if (widget.product != null) IconButton(icon: const Icon(Icons.delete_outline), onPressed: del),
      ]),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Center(
          child: Container(
            width: 160, height: 160,
            decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Colors.grey), borderRadius: BorderRadius.circular(8)),
            child: (f != null && f.existsSync()) ? ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.file(f, fit: BoxFit.cover)) : const Icon(Icons.image_outlined, size: 60, color: Colors.grey),
          ),
        ),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          TextButton.icon(onPressed: () => pick(ImageSource.camera), icon: const Icon(Icons.photo_camera), label: const Text('عکس بگیر')),
          TextButton.icon(onPressed: () => pick(ImageSource.gallery), icon: const Icon(Icons.photo_library), label: const Text('از گالری')),
        ]),
        const SizedBox(height: 8),
        TextField(controller: nameC, decoration: const InputDecoration(labelText: 'نام کالا', border: bd, filled: true, fillColor: Colors.white)),
        const SizedBox(height: 12),
        TextField(controller: codeC, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'کد (عدد زیر بارکد)', border: bd, filled: true, fillColor: Colors.white)),
        const SizedBox(height: 12),
        TextField(controller: barC, decoration: InputDecoration(labelText: 'بارکد', border: bd, filled: true, fillColor: Colors.white, suffixIcon: IconButton(icon: const Icon(Icons.qr_code_scanner), onPressed: scanBar))),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(controller: buyC, keyboardType: TextInputType.number, onChanged: (_) => calc(), decoration: const InputDecoration(labelText: 'قیمت خرید (تومان)', border: bd, filled: true, fillColor: Colors.white))),
          const SizedBox(width: 8),
          SizedBox(width: 100, child: TextField(controller: profC, keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => calc(), decoration: const InputDecoration(labelText: 'سود ٪', border: bd, filled: true, fillColor: Colors.white))),
        ]),
        const SizedBox(height: 12),
        TextField(controller: sellC, keyboardType: TextInputType.number, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold), decoration: const InputDecoration(labelText: 'قیمت فروش (تومان)', border: bd, filled: true, fillColor: Colors.white)),
        const SizedBox(height: 12),
        TextField(controller: qtyC, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'موجودی (تعداد)', border: bd, filled: true, fillColor: Colors.white)),
        const SizedBox(height: 16),
        FilledButton(onPressed: save, child: const Padding(padding: EdgeInsets.all(10), child: Text('ذخیره', style: TextStyle(fontSize: 18)))),
        if (hist.isNotEmpty) ...[
          const Divider(height: 32),
          const Text('تاریخچه‌ی قیمت فروش', style: TextStyle(fontWeight: FontWeight.bold)),
          for (final h in hist) ListTile(dense: true, title: Text('${money(h['s'])} تومان'), trailing: Text(shamsi(DateTime.parse(h['d'])))),
        ],
      ]),
    );
  }
}

// ---------------- Pick product ----------------
class PickPage extends StatefulWidget {
  const PickPage({super.key});
  @override
  State<PickPage> createState() => _PickState();
}

class _PickState extends State<PickPage> {
  String q = '';
  @override
  Widget build(BuildContext context) {
    final k = norm(q);
    final l = items.where((p) => k.isEmpty || norm(p.name).contains(k) || p.code.contains(k)).toList();
    return Scaffold(
      appBar: AppBar(
        title: TextField(autofocus: true, style: const TextStyle(color: Colors.white), cursorColor: Colors.white, decoration: const InputDecoration(hintText: 'جست‌وجوی کالا', hintStyle: TextStyle(color: Colors.white70), border: InputBorder.none), onChanged: (v) => setState(() => q = v)),
      ),
      body: ListView(children: [
        for (final p in l)
          ListTile(title: Text(p.name), subtitle: Text('موجودی: ${fa('${p.qty}')}'), trailing: Text(money(p.sell), style: const TextStyle(fontWeight: FontWeight.bold)), onTap: () => Navigator.pop(context, p)),
      ]),
    );
  }
}

class MultiPickPage extends StatefulWidget {
  const MultiPickPage({super.key});
  @override
  State<MultiPickPage> createState() => _MultiPickState();
}

class _MultiPickState extends State<MultiPickPage> {
  String q = '';
  final ids = <String>{};
  List<Product> get list {
    final k = norm(q);
    return items.where((p) => k.isEmpty || norm(p.name).contains(k) || p.code.contains(k)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final l = list;
    return Scaffold(
      appBar: AppBar(
        title: TextField(style: const TextStyle(color: Colors.white), cursorColor: Colors.white, decoration: const InputDecoration(hintText: 'جست‌وجو', hintStyle: TextStyle(color: Colors.white70), border: InputBorder.none), onChanged: (v) => setState(() => q = v)),
        actions: [
          TextButton(
            onPressed: () => setState(() {
              if (l.every((p) => ids.contains(p.id))) {
                ids.removeAll(l.map((p) => p.id));
              } else {
                ids.addAll(l.map((p) => p.id));
              }
            }),
            child: const Text('همه', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: ListView(children: [
        for (final p in l)
          CheckboxListTile(
            value: ids.contains(p.id),
            onChanged: (v) => setState(() {
              if (v == true) {
                ids.add(p.id);
              } else {
                ids.remove(p.id);
              }
            }),
            title: Text(p.name),
            subtitle: Text('${money(p.sell)} تومان'),
          ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: FilledButton(onPressed: ids.isEmpty ? null : () => Navigator.pop(context, ids), child: Text('ادامه (${fa('${ids.length}')} کالا)')),
        ),
      ),
    );
  }
}

// ---------------- Sale ----------------
class SalePage extends StatefulWidget {
  const SalePage({super.key});
  @override
  State<SalePage> createState() => _SaleState();
}

class _SaleState extends State<SalePage> {
  final lines = <Map<String, dynamic>>[];
  final custC = TextEditingController(), phoneC = TextEditingController(), discC = TextEditingController(), paidC = TextEditingController();
  String pay = 'cash';
  int get sum => lines.fold<int>(0, (a, l) => a + (l['q'] as int) * (l['p'] as int));
  int get total => sum - pInt(discC.text);

  void add(Product p) {
    final i = lines.indexWhere((l) => l['id'] == p.id);
    if (i >= 0) {
      lines[i]['q'] = (lines[i]['q'] as int) + 1;
    } else {
      lines.add({'id': p.id, 'name': p.name, 'q': 1, 'p': p.sell, 'b': p.buy});
    }
    setState(() {});
  }

  Future<void> scan() async {
    final c = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const ScanPage()));
    if (c == null || !mounted) return;
    final p = items.where((e) => e.barcode == c || (e.code.isNotEmpty && e.code == en(c))).firstOrNull;
    if (p == null) {
      snack(context, 'این بارکد ثبت نشده است');
    } else {
      add(p);
    }
  }

  Future<void> pickItem() async {
    final p = await Navigator.push<Product>(context, MaterialPageRoute(builder: (_) => const PickPage()));
    if (p != null) add(p);
  }

  void editPrice(int i) {
    final c = TextEditingController(text: fa('${lines[i]['p']}'));
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('قیمت واحد در این فاکتور'),
        content: TextField(controller: c, keyboardType: TextInputType.number, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('انصراف')),
          FilledButton(onPressed: () { setState(() => lines[i]['p'] = pInt(c.text)); Navigator.pop(context); }, child: const Text('تأیید')),
        ],
      ),
    );
  }

  Future<void> finish() async {
    if (lines.isEmpty) return;
    if (pay == 'credit' && custC.text.trim().isEmpty) {
      snack(context, 'برای فروش نسیه نام مشتری را بنویسید');
      return;
    }
    final inv = Invoice(
      no: st.nextNo, date: DateTime.now(), customer: custC.text.trim(), phone: phoneC.text.trim(), discount: pInt(discC.text),
      pay: pay, paid: pay == 'credit' ? (pInt(paidC.text) > total ? total : pInt(paidC.text)) : total,
      lines: lines.map((l) => Map<String, dynamic>.from(l)).toList(),
    );
    st.nextNo++;
    for (final l in lines) {
      final p = prod(l['id']);
      if (p != null) {
        p.qty -= (l['q'] as int);
        if (p.qty < 0) p.qty = 0;
      }
    }
    invoices.add(inv);
    await saveDb();
    await saveSt();
    await saveInv();
    if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => InvoicePage(inv)));
  }

  @override
  Widget build(BuildContext context) {
    const bd = OutlineInputBorder();
    return Scaffold(
      appBar: AppBar(title: const Text('فروش جدید')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            Expanded(child: FilledButton.icon(onPressed: scan, icon: const Icon(Icons.qr_code_scanner), label: const Text('اسکن بارکد'))),
            const SizedBox(width: 8),
            Expanded(child: FilledButton.tonalIcon(onPressed: pickItem, icon: const Icon(Icons.search), label: const Text('انتخاب از لیست'))),
          ]),
        ),
        Expanded(
          child: lines.isEmpty
              ? const Center(child: Text('کالایی اضافه نشده'))
              : ListView.builder(
                  itemCount: lines.length,
                  itemBuilder: (_, i) {
                    final l = lines[i];
                    final p = prod(l['id']);
                    final over = p != null && (l['q'] as int) > p.qty;
                    return Card(
                      child: ListTile(
                        title: Text(l['name']),
                        subtitle: Wrap(spacing: 8, children: [
                          InkWell(onTap: () => editPrice(i), child: Text('${money(l['p'])} ✎', style: const TextStyle(color: purple, fontWeight: FontWeight.bold))),
                          if (over) Text('موجودی فقط ${fa('${p.qty}')}', style: const TextStyle(color: Colors.red)),
                        ]),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: () => setState(() { if ((l['q'] as int) > 1) { l['q'] = (l['q'] as int) - 1; } else { lines.removeAt(i); } })),
                          Text(fa('${l['q']}'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                          IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: () => setState(() => l['q'] = (l['q'] as int) + 1)),
                          IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red), onPressed: () => setState(() => lines.removeAt(i))),
                        ]),
                      ),
                    );
                  },
                ),
        ),
        Flexible(child: SingleChildScrollView(child: Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: SafeArea(
            top: false,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Expanded(child: TextField(controller: custC, decoration: const InputDecoration(labelText: 'نام مشتری', border: bd, isDense: true))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: phoneC, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'تلفن', border: bd, isDense: true))),
              ]),
              const SizedBox(height: 8),
              TextField(controller: discC, keyboardType: TextInputType.number, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'تخفیف (تومان)', border: bd, isDense: true)),
              const SizedBox(height: 8),
              Row(children: [
                for (final e in const {'cash': 'نقد', 'card': 'کارت', 'credit': 'نسیه'}.entries)
                  Padding(padding: const EdgeInsetsDirectional.only(end: 8), child: ChoiceChip(label: Text(e.value), selected: pay == e.key, onSelected: (_) => setState(() => pay = e.key))),
              ]),
              if (pay == 'credit') ...[
                const SizedBox(height: 8),
                TextField(controller: paidC, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'پیش‌پرداخت (اختیاری)', border: bd, isDense: true)),
              ],
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: Text('جمع: ${money(total)} تومان', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
                FilledButton(onPressed: lines.isEmpty ? null : finish, child: const Text('ثبت فاکتور')),
              ]),
            ]),
          ),
        ))),
      ]),
    );
  }
}

// ---------------- Invoice ----------------
class InvoiceView extends StatelessWidget {
  final Invoice inv;
  const InvoiceView(this.inv, {super.key});
  Widget row(List<String> c, {bool head = false}) {
    const fl = [1, 5, 2, 3, 3];
    return Container(
      color: head ? const Color(0xFFEBDDF3) : null,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      decoration: head ? null : const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFDDDDDD)))),
      child: Row(children: [for (var i = 0; i < 5; i++) Expanded(flex: fl[i], child: Text(c[i], textAlign: i == 1 ? TextAlign.start : TextAlign.center, style: TextStyle(fontSize: 12, fontWeight: head ? FontWeight.bold : FontWeight.normal)))]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      child: DefaultTextStyle(
        style: const TextStyle(color: Colors.black87, fontSize: 13),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (st.logo != null) Padding(padding: const EdgeInsetsDirectional.only(end: 10), child: logoImg(70)),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(st.shop, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: purple)),
                if (st.phone.isNotEmpty) Text('تلفن: ${fa(st.phone)}'),
                if (st.address.isNotEmpty) Text(st.address),
              ])),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('فاکتور فروش', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                Text('شماره: ${fa('${inv.no}')}'),
                Text('تاریخ: ${shamsi(inv.date)}'),
              ]),
            ]),
            const Divider(height: 20, thickness: 2, color: purple),
            if (inv.customer.isNotEmpty || inv.phone.isNotEmpty)
              Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('خریدار: ${inv.customer}${inv.phone.isNotEmpty ? '   تلفن: ${fa(inv.phone)}' : ''}')),
            row(['ردیف', 'شرح کالا', 'تعداد', 'قیمت واحد', 'مبلغ'], head: true),
            for (var i = 0; i < inv.lines.length; i++)
              row([fa('${i + 1}'), inv.lines[i]['name'], fa('${inv.lines[i]['q']}'), money(inv.lines[i]['p']), money((inv.lines[i]['q'] as int) * (inv.lines[i]['p'] as int))]),
            const SizedBox(height: 10),
            Align(alignment: AlignmentDirectional.centerEnd, child: Text('جمع کل: ${money(inv.sum)} تومان')),
            if (inv.discount > 0) Align(alignment: AlignmentDirectional.centerEnd, child: Text('تخفیف: ${money(inv.discount)} تومان')),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: purple, borderRadius: BorderRadius.circular(8)),
              child: Text('مبلغ قابل پرداخت: ${money(inv.total)} تومان', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 8),
            Text('نحوه‌ی پرداخت: ${inv.pay == 'cash' ? 'نقد' : inv.pay == 'card' ? 'کارت' : 'نسیه'}${inv.pay == 'credit' ? ' — پرداخت‌شده: ${money(inv.paid)} • مانده: ${money(inv.total - inv.paid)} تومان' : ''}'),
            if (inv.voided) const Padding(padding: EdgeInsets.only(top: 8), child: Text('این فاکتور باطل شده است', textAlign: TextAlign.center, style: TextStyle(color: Colors.red, fontSize: 18, fontWeight: FontWeight.bold))),
            const SizedBox(height: 18),
            Row(children: const [
              Expanded(child: Text('مهر و امضای فروشنده', textAlign: TextAlign.center, style: TextStyle(fontSize: 11))),
              Expanded(child: Text('امضای خریدار', textAlign: TextAlign.center, style: TextStyle(fontSize: 11))),
            ]),
            const SizedBox(height: 40),
            if (st.footer.isNotEmpty) Text(st.footer, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, color: Colors.black54)),
          ]),
        ),
      ),
    );
  }
}

class InvoicePage extends StatefulWidget {
  final Invoice inv;
  const InvoicePage(this.inv, {super.key});
  @override
  State<InvoicePage> createState() => _InvState();
}

class _InvState extends State<InvoicePage> {
  final key = GlobalKey();

  Future<Uint8List> makePdf() => pdfOfKeys([key]);

  Future<void> voidIt() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('ابطال فاکتور؟'),
        content: const Text('کالاها به موجودی برمی‌گردند و فاکتور از گزارش‌ها و بدهی‌ها حذف می‌شود.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('خیر')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('ابطال')),
        ],
      ),
    );
    if (ok != true) return;
    for (final l in widget.inv.lines) {
      final p = prod(l['id']);
      if (p != null) p.qty += (l['q'] as int);
    }
    widget.inv.voided = true;
    await saveDb();
    await saveInv();
    if (mounted) setState(() {});
  }

  Future<void> savePdf() async {
    final bytes = await makePdf();
    await Printing.layoutPdf(onLayout: (_) async => bytes, name: 'invoice-${widget.inv.no}');
  }

  Future<void> sharePdf() async {
    final bytes = await makePdf();
    await Printing.sharePdf(bytes: bytes, filename: 'invoice-${widget.inv.no}.pdf');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('فاکتور ${fa('${widget.inv.no}')}'), actions: [
          if (widget.inv.debt > 0) IconButton(tooltip: 'ثبت پرداخت', icon: const Icon(Icons.payments), onPressed: () async { await payDialog(context, widget.inv); if (mounted) setState(() {}); }),
          if (!widget.inv.voided) IconButton(tooltip: 'ابطال فاکتور', icon: const Icon(Icons.undo), onPressed: voidIt),
        ]),
        body: SingleChildScrollView(padding: const EdgeInsets.all(8), child: RepaintBoundary(key: key, child: InvoiceView(widget.inv))),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              Expanded(child: FilledButton.icon(onPressed: () => guard(context, savePdf), icon: const Icon(Icons.picture_as_pdf), label: const Text('ذخیره PDF'))),
              const SizedBox(width: 8),
              Expanded(child: FilledButton.tonalIcon(onPressed: () => guard(context, sharePdf), icon: const Icon(Icons.share), label: const Text('ارسال'))),
            ]),
          ),
        ),
      );
}

class InvoicesPage extends StatefulWidget {
  const InvoicesPage({super.key});
  @override
  State<InvoicesPage> createState() => _InvListState();
}

class _InvListState extends State<InvoicesPage> {
  @override
  Widget build(BuildContext context) {
    final l = invoices.reversed.toList();
    return Scaffold(
      appBar: AppBar(title: const Text('فاکتورها')),
      body: l.isEmpty
          ? const Center(child: Text('هنوز فاکتوری صادر نشده'))
          : ListView(children: [
              for (final v in l)
                Card(
                  child: ListTile(
                    title: Text('فاکتور ${fa('${v.no}')}${v.customer.isNotEmpty ? ' — ${v.customer}' : ''}'),
                    subtitle: Text('${shamsi(v.date)}${v.voided ? ' • باطل' : ''}${v.debt > 0 ? ' • مانده ${money(v.debt)}' : ''}', style: TextStyle(color: v.voided ? Colors.red : (v.debt > 0 ? Colors.orange.shade800 : null))),
                    trailing: Text('${money(v.total)} تومان', style: TextStyle(fontWeight: FontWeight.bold, decoration: v.voided ? TextDecoration.lineThrough : null)),
                    onTap: () async {
                      await Navigator.push(context, MaterialPageRoute(builder: (_) => InvoicePage(v)));
                      setState(() {});
                    },
                  ),
                ),
            ]),
    );
  }
}

// ---------------- Settings ----------------
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsState();
}

class _SettingsState extends State<SettingsPage> {
  late final shopC = TextEditingController(text: st.shop);
  late final phoneC = TextEditingController(text: st.phone);
  late final addrC = TextEditingController(text: st.address);
  late final footC = TextEditingController(text: st.footer);
  late final lowC = TextEditingController(text: fa('${st.low}'));
  late final noC = TextEditingController(text: fa('${st.nextNo}'));
  String? logo;
  @override
  void initState() {
    super.initState();
    logo = st.logo;
  }

  Future<void> backup() async {
    final ar = Archive();
    for (final n in ['products.json', 'settings.json', 'invoices.json']) {
      final f = _f(n);
      if (await f.exists()) {
        final b = await f.readAsBytes();
        ar.addFile(ArchiveFile(n, b.length, b));
      }
    }
    for (final e in Directory('${docDir.path}/photos').listSync()) {
      if (e is File) {
        final b = await e.readAsBytes();
        ar.addFile(ArchiveFile('photos/${e.uri.pathSegments.last}', b.length, b));
      }
    }
    final data = ZipEncoder().encode(ar);
    if (data == null) return;
    final tmp = await getTemporaryDirectory();
    final j = Jalali.now();
    final path = '${tmp.path}/asia-backup-${j.year}-${j.month}-${j.day}.zip';
    await File(path).writeAsBytes(data);
    st.lastBackup = DateTime.now().toIso8601String();
    await saveSt();
    await Share.shareXFiles([XFile(path)], text: 'پشتیبان لیست قیمت');
    if (mounted) setState(() {});
  }

  Future<void> restore() async {
    final x = await openFile();
    if (x == null) return;
    try {
      final ar = ZipDecoder().decodeBytes(await x.readAsBytes());
      if (!ar.files.any((f) => f.name == 'products.json' || f.name == 'invoices.json')) {
        if (mounted) snack(context, 'این فایل، پشتیبان این برنامه نیست');
        return;
      }
      if (!mounted) return;
      final yes = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('بازگردانی پشتیبان؟'),
          content: const Text('اطلاعات فعلی برنامه با اطلاعات فایل پشتیبان جایگزین می‌شود.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('انصراف')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('بازگردانی')),
          ],
        ),
      );
      if (yes != true) return;
      for (final f in ar.files) {
        if (!f.isFile || f.name.contains('..')) continue;
        final ok = f.name == 'products.json' || f.name == 'settings.json' || f.name == 'invoices.json' || RegExp(r'^photos/[^/]+$').hasMatch(f.name);
        if (!ok) continue;
        final out = File('${docDir.path}/${f.name}');
        await out.parent.create(recursive: true);
        await out.writeAsBytes(f.content as List<int>);
      }
      await loadDb();
      if (mounted) {
        snack(context, 'بازگردانی انجام شد');
        Navigator.pop(context);
      }
    } catch (_) {
      if (mounted) snack(context, 'خطا در خواندن فایل پشتیبان');
    }
  }

  Future<void> save() async {
    st.shop = shopC.text.trim();
    st.phone = en(phoneC.text).trim();
    st.address = addrC.text.trim();
    st.footer = footC.text.trim();
    st.low = pInt(lowC.text);
    st.nextNo = pInt(noC.text) == 0 ? st.nextNo : pInt(noC.text);
    st.logo = logo;
    await saveSt();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    const bd = OutlineInputBorder();
    final f = logo == null ? null : File('${docDir.path}/photos/$logo');
    return Scaffold(
      appBar: AppBar(title: const Text('تنظیمات فروشگاه')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Card(child: ListTile(leading: const Icon(Icons.help_outline), title: const Text('راهنمای برنامه'), trailing: const Icon(Icons.chevron_left), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HelpPage())))),
        Center(
          child: Container(
            width: 110, height: 110,
            decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Colors.grey), borderRadius: BorderRadius.circular(8)),
            child: (f != null && f.existsSync()) ? Image.file(f, fit: BoxFit.contain) : const Icon(Icons.storefront, size: 50, color: Colors.grey),
          ),
        ),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          TextButton.icon(onPressed: () async { final n = await pickPhoto(ImageSource.gallery); if (n != null) setState(() => logo = n); }, icon: const Icon(Icons.image), label: const Text('انتخاب لوگو')),
          if (logo != null) TextButton(onPressed: () => setState(() => logo = null), child: const Text('حذف لوگو')),
        ]),
        const SizedBox(height: 8),
        TextField(controller: shopC, decoration: const InputDecoration(labelText: 'نام فروشگاه', border: bd, filled: true, fillColor: Colors.white)),
        const SizedBox(height: 12),
        TextField(controller: phoneC, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'تلفن', border: bd, filled: true, fillColor: Colors.white)),
        const SizedBox(height: 12),
        TextField(controller: addrC, maxLines: 2, decoration: const InputDecoration(labelText: 'آدرس', border: bd, filled: true, fillColor: Colors.white)),
        const SizedBox(height: 12),
        TextField(controller: footC, decoration: const InputDecoration(labelText: 'متن پایین فاکتور', border: bd, filled: true, fillColor: Colors.white)),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(controller: lowC, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'هشدار کم‌موجودی (تعداد)', border: bd, filled: true, fillColor: Colors.white))),
          const SizedBox(width: 8),
          Expanded(child: TextField(controller: noC, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'شماره‌ی فاکتور بعدی', border: bd, filled: true, fillColor: Colors.white))),
        ]),
        const SizedBox(height: 16),
        FilledButton(onPressed: save, child: const Padding(padding: EdgeInsets.all(10), child: Text('ذخیره', style: TextStyle(fontSize: 18)))),
        const Divider(height: 32),
        const Text('پشتیبان‌گیری', style: TextStyle(fontWeight: FontWeight.bold)),
        Text(st.lastBackup == null ? 'هنوز پشتیبان نگرفته‌اید' : 'آخرین پشتیبان: ${shamsi(DateTime.parse(st.lastBackup!))}'),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: FilledButton.tonalIcon(onPressed: backup, icon: const Icon(Icons.upload_file), label: const Text('گرفتن پشتیبان'))),
          const SizedBox(width: 8),
          Expanded(child: FilledButton.tonalIcon(onPressed: restore, icon: const Icon(Icons.restore), label: const Text('بازگردانی'))),
        ]),
      ]),
    );
  }
}


// ---------------- Stock in ----------------
class StockInPage extends StatefulWidget {
  const StockInPage({super.key});
  @override
  State<StockInPage> createState() => _StockInState();
}

class _StockInState extends State<StockInPage> {
  final log = <String>[];

  Future<void> scan() async {
    final c = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const ScanPage()));
    if (c == null || !mounted) return;
    final p = items.where((e) => e.barcode == c || (e.code.isNotEmpty && e.code == en(c))).firstOrNull;
    if (p == null) {
      snack(context, 'این کالا ثبت نشده؛ اول از صفحه‌ی اصلی ثبتش کنید');
      return;
    }
    await receive(p);
  }

  Future<void> pick() async {
    final p = await Navigator.push<Product>(context, MaterialPageRoute(builder: (_) => const PickPage()));
    if (p != null) await receive(p);
  }

  Future<void> receive(Product p) async {
    final qC = TextEditingController(text: fa('1'));
    final bC = TextEditingController(text: p.buy == 0 ? '' : fa('${p.buy}'));
    var upd = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(p.name),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('موجودی فعلی: ${fa('${p.qty}')}'),
            TextField(controller: qC, keyboardType: TextInputType.number, autofocus: true, decoration: const InputDecoration(labelText: 'تعداد ورودی')),
            TextField(controller: bC, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'قیمت خرید جدید (تومان)')),
            CheckboxListTile(dense: true, contentPadding: EdgeInsets.zero, value: upd, onChanged: (v) => set(() => upd = v ?? true), title: const Text('قیمت فروش با درصد سود به‌روز شود')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ثبت ورود')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final n = pInt(qC.text);
    if (n <= 0) return;
    p.qty += n;
    final nb = pInt(bC.text);
    if (nb > 0 && nb != p.buy) {
      p.buy = nb;
      if (upd) p.sell = round100(nb * (1 + p.profit / 100));
      p.record();
    }
    await saveDb();
    setState(() => log.insert(0, '${p.name} — ${fa('+$n')} (موجودی: ${fa('${p.qty}')})'));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('ورود کالا به انبار')),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              Expanded(child: FilledButton.icon(onPressed: scan, icon: const Icon(Icons.qr_code_scanner), label: const Text('اسکن بارکد'))),
              const SizedBox(width: 8),
              Expanded(child: FilledButton.tonalIcon(onPressed: pick, icon: const Icon(Icons.search), label: const Text('انتخاب از لیست'))),
            ]),
          ),
          Expanded(
            child: log.isEmpty
                ? const Center(child: Text('کالا را اسکن کنید و تعداد ورودی را بزنید'))
                : ListView(children: [for (final t in log) Card(child: ListTile(leading: const Icon(Icons.check_circle, color: Colors.green), title: Text(t)))]),
          ),
        ]),
      );
}

// ---------------- Report ----------------
class ReportPage extends StatefulWidget {
  const ReportPage({super.key});
  @override
  State<ReportPage> createState() => _ReportState();
}

class _ReportState extends State<ReportPage> {
  int period = 0;
  DateTime? from() {
    final n = DateTime.now();
    final t = DateTime(n.year, n.month, n.day);
    if (period == 0) return t;
    if (period == 1) return t.subtract(const Duration(days: 6));
    if (period == 2) {
      final j = Jalali.fromDateTime(n);
      return Jalali(j.year, j.month, 1).toDateTime();
    }
    return null;
  }

  Widget box(String t, String v, Color c) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [Expanded(child: Text(t)), Text(v, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: c))]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final f = from();
    final l = invoices.where((v) => !v.voided && (f == null || !v.date.isBefore(f))).toList();
    final sales = l.fold<int>(0, (a, v) => a + v.total);
    final profit = l.fold<int>(0, (a, v) => a + v.profit);
    final debt = l.fold<int>(0, (a, v) => a + v.debt);
    final sold = <String, int>{};
    for (final v in l) {
      for (final x in v.lines) {
        sold[x['name']] = (sold[x['name']] ?? 0) + (x['q'] as int);
      }
    }
    final top = sold.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    const names = ['امروز', '۷ روز اخیر', 'این ماه', 'همه'];
    return Scaffold(
      appBar: AppBar(title: const Text('گزارش فروش')),
      body: ListView(padding: const EdgeInsets.all(8), children: [
        Wrap(spacing: 8, children: [for (var i = 0; i < 4; i++) ChoiceChip(label: Text(names[i]), selected: period == i, onSelected: (_) => setState(() => period = i))]),
        const SizedBox(height: 8),
        box('تعداد فاکتور', fa('${l.length}'), Colors.black87),
        box('جمع فروش', '${money(sales)} تومان', purple),
        box('سود تقریبی', '${money(profit)} تومان', Colors.green.shade700),
        box('مانده‌ی نسیه', '${money(debt)} تومان', debt > 0 ? Colors.red : Colors.black87),
        const Padding(padding: EdgeInsets.fromLTRB(8, 4, 8, 0), child: Text('سود فقط برای کالاهایی حساب می‌شود که قیمت خرید دارند.', style: TextStyle(fontSize: 11, color: Colors.black54))),
        if (top.isNotEmpty) ...[
          const Padding(padding: EdgeInsets.fromLTRB(8, 14, 8, 4), child: Text('پرفروش‌ترین‌ها', style: TextStyle(fontWeight: FontWeight.bold))),
          for (final e in top.take(5)) Card(child: ListTile(dense: true, title: Text(e.key), trailing: Text('${fa('${e.value}')} عدد'))),
        ],
      ]),
    );
  }
}

// ---------------- Debtors ----------------
class DebtPage extends StatefulWidget {
  const DebtPage({super.key});
  @override
  State<DebtPage> createState() => _DebtState();
}

class _DebtState extends State<DebtPage> {
  @override
  Widget build(BuildContext context) {
    final l = invoices.where((v) => v.debt > 0).toList()..sort((a, b) => a.date.compareTo(b.date));
    final total = l.fold<int>(0, (a, v) => a + v.debt);
    return Scaffold(
      appBar: AppBar(title: const Text('بدهکاران')),
      body: Column(children: [
        Card(child: ListTile(title: const Text('جمع مطالبات'), trailing: Text('${money(total)} تومان', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.red)))),
        Expanded(
          child: l.isEmpty
              ? const Center(child: Text('بدهکاری وجود ندارد'))
              : ListView(children: [
                  for (final v in l)
                    Card(
                      child: ListTile(
                        title: Text(v.customer.isEmpty ? 'بدون نام' : v.customer),
                        subtitle: Text('فاکتور ${fa('${v.no}')} • ${shamsi(v.date)}${v.phone.isNotEmpty ? ' • ${fa(v.phone)}' : ''}'),
                        trailing: Text(money(v.debt), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
                        onTap: () async {
                          await payDialog(context, v);
                          setState(() {});
                        },
                      ),
                    ),
                ]),
        ),
      ]),
    );
  }
}

// ---------------- Price list (image / PDF) ----------------
class PriceListPage extends StatefulWidget {
  final List<Product> list;
  const PriceListPage(this.list, {super.key});
  @override
  State<PriceListPage> createState() => _PLState();
}

class _PLState extends State<PriceListPage> {
  static const per = 28;
  late final sorted = [...widget.list]..sort((a, b) => a.name.compareTo(b.name));
  late final chunks = [for (var i = 0; i < sorted.length; i += per) sorted.sublist(i, i + per > sorted.length ? sorted.length : i + per)];
  late final keys = List.generate(chunks.length, (_) => GlobalKey());

  Future<void> savePdf() async {
    final b = await pdfOfKeys(keys);
    await Printing.layoutPdf(onLayout: (_) async => b, name: 'price-list');
  }

  Future<void> sharePdf() async {
    final b = await pdfOfKeys(keys);
    await Printing.sharePdf(bytes: b, filename: 'price-list.pdf');
  }

  Future<void> shareImg() async {
    final tmp = await getTemporaryDirectory();
    final files = <XFile>[];
    for (var i = 0; i < keys.length; i++) {
      final png = await pngOf(await capture(keys[i]));
      final f = File('${tmp.path}/price-list-${i + 1}.png');
      await f.writeAsBytes(png);
      files.add(XFile(f.path));
    }
    await Share.shareXFiles(files);
  }

  Widget chunk(int i) => Material(
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (i == 0) ...[
              Row(children: [
                if (st.logo != null) ...[logoImg(56), const SizedBox(width: 10)],
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(st.shop, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: purple)),
                  Text('لیست قیمت — ${shamsi(DateTime.now())}', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                ])),
              ]),
              const Divider(height: 18, thickness: 2, color: purple),
            ],
            for (var k = 0; k < chunks[i].length; k++)
              Container(
                color: k.isEven ? const Color(0xFFF6F2F9) : Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
                child: Row(children: [
                  Expanded(child: Text(chunks[i][k].name, style: const TextStyle(fontSize: 13, color: Colors.black87))),
                  Text('${money(chunks[i][k].sell)} تومان', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.black87)),
                ]),
              ),
            if (i == chunks.length - 1 && st.phone.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Text('تلفن: ${fa(st.phone)}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: Colors.black54))),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('لیست قیمت')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var i = 0; i < chunks.length; i++) Padding(padding: const EdgeInsets.only(bottom: 8), child: RepaintBoundary(key: keys[i], child: chunk(i))),
          ]),
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              Expanded(child: FilledButton.icon(onPressed: () => guard(context, savePdf), icon: const Icon(Icons.picture_as_pdf), label: const Text('ذخیره PDF'))),
              const SizedBox(width: 6),
              Expanded(child: FilledButton.tonalIcon(onPressed: () => guard(context, sharePdf), icon: const Icon(Icons.share), label: const Text('PDF'))),
              const SizedBox(width: 6),
              Expanded(child: FilledButton.tonalIcon(onPressed: () => guard(context, shareImg), icon: const Icon(Icons.image), label: const Text('عکس'))),
            ]),
          ),
        ),
      );
}


// ---------------- Help ----------------
class HelpPage extends StatelessWidget {
  const HelpPage({super.key});
  static const items2 = [
    ['شروع سریع', 'ابتدا از «تنظیمات» نام فروشگاه، تلفن، آدرس و لوگوی خودتان را وارد کنید؛ همه‌ی فاکتورها و لیست قیمت‌ها با همین اطلاعات ساخته می‌شوند. بعد کالاهایتان را ثبت کنید.'],
    ['ثبت کالا', 'دکمه‌ی + (یا اسکن بارکدِ کالای جدید) صفحه‌ی ثبت را باز می‌کند. نام، کد، بارکد، قیمت خرید، درصد سود و موجودی را بنویسید. قیمت فروش خودکار از قیمت خرید و درصد سود حساب می‌شود، ولی می‌توانید دستی تغییرش دهید. عکس کالا را هم با دوربین یا از گالری اضافه کنید.'],
    ['اسکن بارکد', 'دکمه‌ی بزرگ دوربین، بارکد را می‌خواند. اگر کالا ثبت شده باشد قیمت و موجودی‌اش را بزرگ نشان می‌دهد و اگر نه، صفحه‌ی ثبت کالای جدید باز می‌شود. برای جای کم‌نور از دکمه‌ی فلش بالای صفحه‌ی اسکن استفاده کنید. اگر بارکد خراب بود، «تایپ دستی کد» را بزنید.'],
    ['رنگ‌های لیست', 'نقطه‌ی کنار هر کالا نشان می‌دهد قیمتش چند وقت پیش عوض شده: سبز تازه، نارنجی بعد از ۱۴ روز و قرمز بعد از ۳۰ روز. موجودی قرمز یعنی کمتر از حد هشدار (در تنظیمات قابل تغییر است).'],
    ['تغییر قیمت گروهی', 'دکمه‌ی فلشِ بالای صفحه: برای همه‌ی کالاها یا فقط کالاهای انتخاب‌شده درصد افزایش یا کاهش می‌زند. برای انتخاب چند کالا، انگشت را روی آن‌ها نگه دارید.'],
    ['فروش و فاکتور', 'از «فروش جدید» کالاها را با اسکن یا از لیست اضافه کنید، تعداد را تنظیم کنید و در صورت نیاز قیمت یا تخفیف را عوض کنید. نحوه‌ی پرداخت (نقد، کارت، نسیه) را انتخاب و «ثبت فاکتور» را بزنید؛ موجودی کالاها خودکار کم می‌شود. فاکتور را می‌توانید PDF کنید یا برای مشتری بفرستید.'],
    ['نسیه و بدهکاران', 'در فروش نسیه، نام مشتری لازم است و می‌توانید پیش‌پرداخت بگیرید. در صفحه‌ی «بدهکاران» با لمس هر مورد، پرداخت‌های بعدی را ثبت کنید.'],
    ['ابطال فاکتور', 'داخل فاکتور، دکمه‌ی فلش برگشت: کالاها به موجودی برمی‌گردند و فاکتور از گزارش و بدهی‌ها حذف می‌شود.'],
    ['ورود کالا', 'وقتی جنس جدید می‌خرید، از «ورود کالا» آن را اسکن کنید، تعداد و قیمت خرید جدید را بزنید تا موجودی زیاد و در صورت تمایل قیمت فروش به‌روز شود.'],
    ['گزارش', 'فروش، سود تقریبی، مانده‌ی نسیه و پرفروش‌ترین کالاها برای امروز، ۷ روز اخیر، این ماه و کل. سود فقط برای کالاهایی حساب می‌شود که قیمت خرید دارند.'],
    ['لیست قیمت برای مشتری', 'دکمه‌ی اشتراک بالای صفحه‌ی اصلی: ارسال به‌صورت متن، یا «لیست قیمت مرتب» با لوگو و تاریخ که به‌صورت PDF یا عکس ذخیره و ارسال می‌شود.'],
    ['پشتیبان‌گیری (مهم)', 'همه‌ی اطلاعات فقط روی همین گوشی ذخیره است و جای دیگری ارسال نمی‌شود؛ پس اگر گوشی گم یا خراب شود یا برنامه پاک شود، اطلاعات از بین می‌رود. مرتب از «تنظیمات ← گرفتن پشتیبان» یک فایل بگیرید و در تلگرام، Google Drive یا کامپیوتر نگه دارید. برای انتقال به گوشی جدید از «بازگردانی» استفاده کنید.'],
  ];
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('راهنمای برنامه')),
        body: ListView(padding: const EdgeInsets.all(8), children: [
          Center(child: Padding(padding: const EdgeInsets.all(12), child: Image.asset('assets/logo.png', height: 90))),
          const Center(child: Text('نسخه‌ی ۱٫۰٫۰', style: TextStyle(color: Colors.black54))),
          const SizedBox(height: 8),
          for (final e in items2) Card(child: ExpansionTile(title: Text(e[0], style: const TextStyle(fontWeight: FontWeight.bold)), childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14), expandedCrossAxisAlignment: CrossAxisAlignment.start, children: [Text(e[1], style: const TextStyle(height: 1.7))])),
        ]),
      );
}
