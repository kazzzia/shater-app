// ═══════════════════════════════════════════════════════════════════════════
// شطارة — غلاف iOS/أندرويد للموقع (WebView)
//
// كل المنتج يعيش في shatarah.sa — هذا الغلاف نافذة له فقط.
// الفائدة: أيقونة بالمتجر + TestFlight، وأي نشرة ويب توصل فورًا بلا بناء.
//
// ⚠️ أهم سطرين في الملف كله: تشغيل الصوت بلا لمسة من المستخدم
// (allowsInlineMediaPlayback + mediaTypesRequiringUserAction: none) —
// بلاهما صوت مريم لا يشتغل تلقائيًا داخل WebView على iOS، وهو قلب المنتج.
// ═══════════════════════════════════════════════════════════════════════════
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

// ?native=ios|android: الموقع يعرف أنه داخل التطبيق (دفع المتاجر · إخفاء ما لا يُسمح به داخل التطبيقات)
// SHATER_HOME لبناء تجربة فقط (المحاكي على خادمٍ محلي) — الإصدار يُبنى بلاه
const String _homeOverride = String.fromEnvironment('SHATER_HOME');
final String kHome = _homeOverride.isNotEmpty
    ? '$_homeOverride/app?native=${Platform.isIOS ? 'ios' : 'android'}'
    : 'https://shatarah.sa/app?native=${Platform.isIOS ? 'ios' : 'android'}';
// نطاقات الموقع داخل الغلاف — نفسها WKAppBoundDomains في ios/Runner/Info.plist. غيرها يُفتح خارج التطبيق.
final Set<String> kAppHosts = {'shatarah.sa', 'www.shatarah.sa', if (_homeOverride.isNotEmpty) Uri.parse(_homeOverride).host};

// 🍎 معرّفات منتجات الاشتراك — نفسها في App Store Connect وGoogle Play.
// أي منتج جديد يُضاف هنا وفي api/_iap.js (PRODUCTS) معًا، وإلا رفضه الخادم.
// طفلٌ واحد بلا رقم (كما أُنشئ أول مرة)، ثم ٢..٥ بالرقم — نفس ما في
// api/_iap.js (PRODUCTS) وapp.html (iapPid). يفحص التطابقَ check_iap.js.
const Set<String> kProductIds = {
  'sa.shatarah.monthly', 'sa.shatarah.yearly',
  'sa.shatarah.monthly2', 'sa.shatarah.yearly2',
  'sa.shatarah.monthly3', 'sa.shatarah.yearly3',
  'sa.shatarah.monthly4', 'sa.shatarah.yearly4',
  'sa.shatarah.monthly5', 'sa.shatarah.yearly5',
};

Future<void> enterShaterFullscreen() async {
  if (Platform.isAndroid) {
    await const MethodChannel('sa.shatarah/display').invokeMethod<void>('immersive');
  } else {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // StoreKit 2 هو الافتراضي في in_app_purchase_storekit 0.4+: المعاملة تصل
  // موقَّعة (JWS) فيتحقّق منها خادمنا بلا مفتاح سرّي. لا نستدعي enableStoreKit2
  // (صارت مهجورة) — لكن لو رجعت الحزمة يومًا إلى StoreKit 1 فسيتغيّر شكل
  // serverVerificationData إلى إيصال، وسيرفضه api/_iap.js برمز jws-shape.
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  // 🖥️ (فارس ١٢ أكتوبر: «شيل الوقت والشبكة، خلّ التطبيق ياخذ راحته بشكل كامل، ما في شي فوقه» · وبالأندرويد
  // «الصفحة تبقى تحت خيارات الجوال») شاشة كاملة: شريط الحالة وأزرار النظام مخفية، وتظهر بسحبة من الحافة ثم تختفي.
  unawaited(enterShaterFullscreen());
  runApp(const ShaterApp());
}

class ShaterApp extends StatelessWidget {
  const ShaterApp({super.key});
  @override
  Widget build(BuildContext context) => const MaterialApp(
        title: 'شطارة',
        debugShowCheckedModeBanner: false,
        home: ShaterShell(),
      );
}

class ShaterShell extends StatefulWidget {
  const ShaterShell({super.key});
  @override
  State<ShaterShell> createState() => _ShaterShellState();
}

class _ShaterShellState extends State<ShaterShell> with WidgetsBindingObserver {
  late final WebViewController _web;

  Timer? _systemUiRestore;

  @override
  void didChangeMetrics() {
    if (!Platform.isAndroid) return;
    _systemUiRestore?.cancel();
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty || views.first.viewInsets.bottom > 0) return;
    // Android requires at least one second after the keyboard closes.
    _systemUiRestore = Timer(const Duration(milliseconds: 1100), () {
      if (mounted && WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        unawaited(enterShaterFullscreen());
      }
    });
  }

  // الرجوع من الخلفية أو من لوحة المفاتيح/نافذة النظام يعيد الأشرطة — نخفيها من جديد
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _systemUiRestore?.cancel();
    if (state == AppLifecycleState.resumed) {
      unawaited(enterShaterFullscreen());
    }
  }

  bool _loading = true;
  int _progress = 0; // ٠–١٠٠ من WebView — يملأ شريط شاشة الفتح
  bool _offline = false;
  Timer? _watchdog; // لو الصفحة علقت ٢٥ ثانية نعرض «أعد المحاولة» بدل بياض أبدي
  String? _jsErr; // آخر خطأ من الموقع — يظهر بشريط صغير ليسهل التبليغ

  // يلتقط أخطاء الموقع ويمنع النوافذ المنبثقة من الضياع
  static const String _errHook = '''
window.open=function(u){if(u)location.href=u;return null;};
if(!window.__shErrHooked){window.__shErrHooked=1;
window.addEventListener('error',function(e){try{ShaterErr.postMessage((e.message||'خطأ')+' — '+String(e.filename||'').split('/').pop()+':'+(e.lineno||0))}catch(_){}});
window.addEventListener('unhandledrejection',function(e){try{ShaterErr.postMessage('promise: '+(e.reason&&e.reason.message?e.reason.message:e.reason))}catch(_){}});
}''';

  // ═══ جسر التسميع اللحظي (ShaterSTT) ═══
  // قناة ShaterSTT تنشئ window.ShaterSTT.postMessage تلقائيًا — هنا نكمّلها
  // بواجهة startLive/stopLive التي يكتشفها الموقع (recite.js) فيقدّم الجسر
  // على Web Speech المعطوب داخل الغلاف (WebKit bug 239816).
  static const String _sttHook = '''
if(window.ShaterSTT&&!window.ShaterSTT.startLive){
window.ShaterSTT.startLive=function(){window.ShaterSTT.postMessage('start');};
window.ShaterSTT.stopLive=function(){window.ShaterSTT.postMessage('stop');};
}''';

  // ═══ 🔔 إشعارات مجدولة على الجهاز (ShaterNotif) ═══
  // المشكلة: كل إشعاراتنا كانت تُكتب في صندوق داخل الموقع، فلا يراها الأب
  // إلا إذا فتح التطبيق — وهو بالضبط ما لا يفعله حين ننبّهه ألّا ينساه.
  // الحل بلا خادم دفع ولا مفاتيح: الموقع يحسب المواعيد (يعرف الأسماء والجنس
  // والجدول والإعدادات) ويسلّمها جاهزةً، والغلاف يجدولها على الجهاز.
  //   الموقع ⟵ {op:'ask'}                        ⟶ طلب الإذن مرة واحدة
  //   الموقع ⟵ {op:'set', items:[{id,at,title,body}]} ⟶ يلغي القديم ويجدول الجديد
  //   الموقع ⟵ {op:'clear'}                      ⟶ إلغاء الكل
  // «at» زمنٌ محليّ ISO بلا منطقة (2026-09-20T17:00:00) — ساعة الجهاز هي المرجع.

  static const String _notifHook = '''
(function(){
var n=window.ShaterNotif;
if(!n||n.bridgeVersion===2)return;
var pending={},seq=0;
window.__shNotifReply=function(r){
 var p=pending[r.requestId];if(!p)return;
 delete pending[r.requestId];clearTimeout(p.timer);
 if(r.ok===false)p.reject(Error(r.error||'notification-failed'));else p.resolve(r);
};
function call(op,body){
 return new Promise(function(resolve,reject){
  var id=String(Date.now())+'-'+(++seq);
  var timer=setTimeout(function(){delete pending[id];reject(Error('notification-timeout'));},op==='ask'?120000:20000);
  pending[id]={resolve:resolve,reject:reject,timer:timer};
  try{n.postMessage(JSON.stringify(Object.assign({op:op,requestId:id},body||{})));}
  catch(e){clearTimeout(timer);delete pending[id];reject(e);}
 });
}
n.ask=function(){return call('ask');};
n.status=function(){return call('status');};
n.set=function(items){return call('set',{items:items||[]});};
n.clear=function(){return call('clear');};
n.show=function(item){return call('show',{item:item});};
n.native=true;n.bridgeVersion=2;
try{if(window.__shNotifReady)window.__shNotifReady();}catch(_){}
})();
''';

  final FlutterLocalNotificationsPlugin _fln = FlutterLocalNotificationsPlugin();
  Future<void>? _notifInitPending;
  Future<void> _notifQueue = Future<void>.value();

  Future<void> _notifInit() {
    return _notifInitPending ??= _initNotifications().catchError((Object error) {
      _notifInitPending = null;
      throw error;
    });
  }

  Future<void> _initNotifications() async {
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Riyadh'));
    await _fln.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false),
    ));
  }

  Future<bool> _notifAllowed() async {
    await _notifInit();
    if (Platform.isIOS) {
      final p = await _fln
          .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
          ?.checkPermissions();
      return p?.isEnabled ?? false;
    }
    return await _fln
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.areNotificationsEnabled() ?? false;
  }

  Future<Map<String, dynamic>> _notifAsk() async {
    await _notifInit();
    bool? allowed;
    if (Platform.isIOS) {
      allowed = await _fln
          .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } else {
      allowed = await _fln
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    }
    return {'permission': allowed == true ? 'granted' : 'denied'};
  }

  static const NotificationDetails _notifStyle = NotificationDetails(
    android: AndroidNotificationDetails('shatarah_daily', 'تذكيرات شطارة',
        channelDescription: 'تذكير المذاكرة وتنبيه الأهل وموعد الاختبار',
        importance: Importance.defaultImportance, priority: Priority.defaultPriority),
    iOS: DarwinNotificationDetails(),
  );

  Future<Map<String, dynamic>> _notifSet(List<dynamic> items) async {
    await _notifInit();
    if (!await _notifAllowed()) throw StateError('notification-permission-denied');
    await _fln.cancelAll();
    final now = DateTime.now();
    final ids = <int>{};
    var requested = 0;
    for (final raw in items.take(48)) {
      if (raw is! Map) continue;
      final at = DateTime.tryParse('${raw['at']}');
      if (at == null || !at.isAfter(now)) continue;
      final id = int.tryParse('${raw['id']}');
      if (id == null || id < 1 || id > 100000 || !ids.add(id)) {
        throw StateError('notification-invalid-id');
      }
      requested++;
      await _fln.zonedSchedule(
        id, '${raw['title'] ?? 'شطارة'}', '${raw['body'] ?? ''}',
        tz.TZDateTime.from(at, tz.local), _notifStyle,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      );
    }
    final pending = await _fln.pendingNotificationRequests();
    final confirmed = pending.where((p) => ids.contains(p.id)).length;
    if (confirmed != requested) throw StateError('notification-schedule-incomplete');
    return {'permission': 'granted', 'scheduled': confirmed};
  }

  Future<void> _notifRespond(Map<String, dynamic> o) async {
    Map<String, dynamic> result;
    try {
      switch (o['op']) {
        case 'ask':
          result = await _notifAsk();
          break;
        case 'status':
          result = {'permission': await _notifAllowed() ? 'granted' : 'denied',
                    'scheduled': (await _fln.pendingNotificationRequests()).length};
          break;
        case 'set':
          result = await _notifSet((o['items'] as List?) ?? const []);
          break;
        case 'clear':
          await _notifInit();
          await _fln.cancelAll();
          result = {'scheduled': 0};
          break;
        case 'show':
          if (!await _notifAllowed()) throw StateError('notification-permission-denied');
          final item = o['item'] as Map? ?? const {};
          await _fln.show(100001, '${item['title'] ?? 'شطارة'}',
              '${item['body'] ?? ''}', _notifStyle);
          result = {};
          break;
        default:
          throw StateError('notification-unknown-operation');
      }
      result['ok'] = true;
    } catch (_) {
      result = {'ok': false, 'error': 'notification-operation-failed'};
    }
    result['requestId'] = o['requestId'];
    if (!mounted || o['requestId'] == null) return;
    try {
      await _web.runJavaScript('window.__shNotifReply && window.__shNotifReply(${jsonEncode(result)});');
    } catch (_) {}
  }

  // ═══ 💳 جسر الدفع (ShaterPay) ═══
  // الموقع يعرف الجوال والباقة؛ الغلاف يعرف المتجر. فاصلٌ نظيف:
  //   الموقع ⟵ {op:'products'}            ⟶ __shPay({ev:'products', items:[…]})
  //   الموقع ⟵ {op:'buy', product:'…'}    ⟶ __shPay({ev:'purchased', store, data|json+sig})
  //   الموقع ⟵ {op:'restore'}             ⟶ نفس purchased لكل اشتراكٍ قائم
  // الموقع وحده من يرسل الإثبات لخادمنا، لأنه وحده يعرف رقم الجوال.
  static const String _payHook = '''
if(window.ShaterPay&&!window.ShaterPay.buy){
window.ShaterPay.buy=function(p){window.ShaterPay.postMessage(JSON.stringify({op:'buy',product:p}));};
window.ShaterPay.restore=function(){window.ShaterPay.postMessage(JSON.stringify({op:'restore'}));};
window.ShaterPay.products=function(){window.ShaterPay.postMessage(JSON.stringify({op:'products'}));};
window.ShaterPay.ready=true;
try{if(window.__shPayReady)window.__shPayReady();}catch(_){}
}''';

  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _iapSub;
  bool _iapStarted = false;

  // الرد للموقع — jsonEncode يضمن نصًّا سليمًا مهما كان المحتوى
  void _payOut(Map<String, dynamic> msg) {
    _sttJs('if(window.__shPay)window.__shPay(${jsonEncode(jsonEncode(msg))});');
  }

  Future<void> _payStart() async {
    if (_iapStarted) return;
    _iapStarted = true;
    _iapSub = _iap.purchaseStream.listen(_onPurchases, onError: (e) {
      _payOut({'ev': 'error', 'reason': e.toString()});
    });
  }

  Future<void> _payProducts() async {
    await _payStart();
    if (!await _iap.isAvailable()) {
      _payOut({'ev': 'error', 'reason': 'store-unavailable'});
      return;
    }
    final r = await _iap.queryProductDetails(kProductIds);
    _payOut({
      'ev': 'products',
      'items': r.productDetails
          .map((p) => {'id': p.id, 'title': p.title, 'price': p.price, 'raw': p.rawPrice, 'cur': p.currencyCode})
          .toList(),
      'missing': r.notFoundIDs,
    });
  }

  Future<void> _payBuy(String productId) async {
    await _payStart();
    if (!kProductIds.contains(productId)) {
      _payOut({'ev': 'error', 'reason': 'unknown-product'});
      return;
    }
    if (!await _iap.isAvailable()) {
      _payOut({'ev': 'error', 'reason': 'store-unavailable'});
      return;
    }
    final r = await _iap.queryProductDetails({productId});
    if (r.productDetails.isEmpty) {
      _payOut({'ev': 'error', 'reason': 'product-not-found'});
      return;
    }
    // اشتراك = غير مستهلَك: buyNonConsumable هو الصحيح للاثنين
    await _iap.buyNonConsumable(
        purchaseParam: PurchaseParam(productDetails: r.productDetails.first));
  }

  Future<void> _payRestore() async {
    await _payStart();
    try {
      await _iap.restorePurchases();
    } catch (e) {
      _payOut({'ev': 'error', 'reason': e.toString()});
    }
  }

  // كل تغيّر في حالة الشراء يمرّ هنا — ونُكمل المعاملة بعد إبلاغ الموقع
  Future<void> _onPurchases(List<PurchaseDetails> list) async {
    for (final p in list) {
      if (p.status == PurchaseStatus.pending) {
        _payOut({'ev': 'pending', 'product': p.productID});
        continue;
      }
      if (p.status == PurchaseStatus.error || p.status == PurchaseStatus.canceled) {
        _payOut({
          'ev': p.status == PurchaseStatus.canceled ? 'canceled' : 'error',
          'product': p.productID,
          'reason': p.error?.message ?? '',
        });
      } else if (p.status == PurchaseStatus.purchased ||
                 p.status == PurchaseStatus.restored) {
        final v = p.verificationData;
        if (Platform.isIOS) {
          // StoreKit 2: serverVerificationData = المعاملة الموقَّعة (JWS)
          _payOut({
            'ev': 'purchased', 'store': 'ios', 'product': p.productID,
            'restored': p.status == PurchaseStatus.restored,
            'data': v.serverVerificationData,
          });
        } else {
          // Play: النصّ الأصلي + توقيع جوجل عليه
          _payOut({
            'ev': 'purchased', 'store': 'android', 'product': p.productID,
            'restored': p.status == PurchaseStatus.restored,
            'json': v.localVerificationData,
            'sig': (p is GooglePlayPurchaseDetails) ? p.billingClientPurchase.signature : '',
            'token': v.serverVerificationData,
          });
        }
      }
      // إكمال المعاملة واجبٌ على المنصتين، وإلا استُرجعت الدفعة تلقائيًا
      if (p.pendingCompletePurchase) {
        try { await _iap.completePurchase(p); } catch (_) {}
      }
    }
  }

  // التعرف اللحظي الأصلي — نتائجه الجزئية تُبث للموقع أولًا بأول
  final stt.SpeechToText _stt = stt.SpeechToText();
  bool _sttReady = false;
  String? _sttLocale;

  // تنفيذ JS داخل الويب فيو بأمان — أعطال الجسر لا تُسقط التطبيق أبدًا
  void _sttJs(String js) {
    _web.runJavaScript(js).catchError((_) {});
  }

  // كل نتيجة جزئية → window.__shaterSttPartial(نص، نهائي؟)
  // jsonEncode يحوّل النص لعبارة JS سليمة مهما كان فيه (عربي/أقواس/أسطر)
  void _sttPartial(String text, bool isFinal) {
    _sttJs('if(window.__shaterSttPartial)window.__shaterSttPartial('
        '${jsonEncode(text)},$isFinal);');
  }

  Future<void> _sttStart() async {
    try {
      if (!_sttReady) {
        _sttReady = await _stt.initialize(
          onError: (e) {
            final msg = e.errorMsg;
            // «ما فيه كلام» نهاية طبيعية للجلسة لا عطل — الموقع يحكم بما سمع
            if (msg.contains('no_match') || msg.contains('speech_timeout')) {
              _sttJs('if(window.__shaterSttEnd)window.__shaterSttEnd();');
            } else {
              _sttJs('if(window.__shaterSttError)window.__shaterSttError('
                  '${jsonEncode(msg)});');
            }
          },
          onStatus: (s) {
            if (s == 'done' || s == 'notListening') {
              _sttJs('if(window.__shaterSttEnd)window.__shaterSttEnd();');
            }
          },
        );
      }
      if (!_sttReady) {
        _sttJs("if(window.__shaterSttError)window.__shaterSttError('stt-unavailable');");
        return;
      }
      // العربية السعودية إن وُجدت، وإلا أي عربية متاحة بالجهاز
      if (_sttLocale == null) {
        String pick = 'ar-SA';
        final locales = await _stt.locales();
        var found = false;
        for (final l in locales) {
          if (l.localeId.replaceAll('_', '-').toLowerCase().startsWith('ar-sa')) {
            pick = l.localeId;
            found = true;
            break;
          }
        }
        if (!found) {
          for (final l in locales) {
            if (l.localeId.toLowerCase().startsWith('ar')) {
              pick = l.localeId;
              break;
            }
          }
        }
        _sttLocale = pick;
      }
      await _stt.listen(
        onResult: (r) => _sttPartial(r.recognizedWords, r.finalResult),
        listenOptions: stt.SpeechListenOptions(
          localeId: _sttLocale,
          partialResults: true,
          listenMode: stt.ListenMode.dictation,
          pauseFor: const Duration(seconds: 5),
          listenFor: const Duration(seconds: 75),
          cancelOnError: true,
        ),
      );
    } catch (e) {
      _sttJs('if(window.__shaterSttError)window.__shaterSttError('
          '${jsonEncode(e.toString())});');
    }
  }

  void _sttStop() {
    try {
      _stt.stop();
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // ⚠️ إعدادات المنصة قبل الإنشاء — الصوت التلقائي على iOS يتقرر هنا
    // ولا يمكن تفعيله بعد إنشاء المتحكم
    late final PlatformWebViewControllerCreationParams params;
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
        // 📴 (فارس ٢٩ أكتوبر: «أبي التطبيق يشتغل حتى بدون إنترنت») WKWebView لا يشغّل عامل الخدمة (sw.js) إلا لتطبيقٍ
        // يعلن نطاقاته المربوطة (WKAppBoundDomains في Info.plist + هذا القيد). بلاه: لا فتح بلا نت، وكل فتحٍ ينزّل app.html (١٫٤ م.ب).
        // القيد يمنع فتح أي نطاقٍ آخر داخل الغلاف — فتلك الروابط تُفتح في تطبيقها (_external في onNavigationRequest).
        limitsNavigationsToAppBoundDomains: true,
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }
    _web = WebViewController.fromPlatformCreationParams(
      params,
      onPermissionRequest: (req) => req.grant(), // المايك لأزرار التسميع
    );
    // أندرويد: نفس الشيء — الصوت بلا إيماءة مستخدم
    if (_web.platform is AndroidWebViewController) {
      (_web.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);
    }
    // آيفون: السحب من حافة الشاشة يرجع للصفحة السابقة (ما فيه أزرار متصفح)
    if (_web.platform is WebKitWebViewController) {
      (_web.platform as WebKitWebViewController)
          .setAllowsBackForwardNavigationGestures(true);
    }
    // 📷 (فارس ٢٩ أكتوبر: «امسح الكود… يقفل التطبيق») — 1.0.2 بلا NSCameraUsageDescription فكان iOS يقتل التطبيق عند فتح الكاميرا.
    // الإذن الآن في Info.plist، ووجود ShaterCam يقول للموقع (SH_CAM_OFF في app.html) إن المسح متاح.
    // أندرويد بلا إذن كاميرا وقت التشغيل بعد ⟵ لا ShaterCam ويبقى «اكتب الكود».
    if (Platform.isIOS) {
      _web.addJavaScriptChannel('ShaterCam', onMessageReceived: (_) {});
    }
    _web
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFF4F7FC)) // أرضية التطبيق (theme_pomo) — لا وميض أبيض
      ..addJavaScriptChannel('ShaterErr',
          onMessageReceived: (m) => setState(() => _jsErr = m.message))
      // جسر التسميع اللحظي: الموقع يرسل start/stop ونحن نبث النتائج الجزئية له
      ..addJavaScriptChannel('ShaterSTT', onMessageReceived: (m) {
        if (m.message == 'start') {
          _sttStart();
        } else if (m.message == 'stop') {
          _sttStop();
        }
      })
      // 🔔 جسر الإشعارات المجدولة
      ..addJavaScriptChannel('ShaterNotif', onMessageReceived: (m) {
        Map<String, dynamic> o;
        try { o = jsonDecode(m.message) as Map<String, dynamic>; } catch (_) { return; }
        _notifQueue = _notifQueue.then((_) => _notifRespond(o));
      })
      // 💳 جسر دفع المتجر
      ..addJavaScriptChannel('ShaterPay', onMessageReceived: (m) {
        Map<String, dynamic> o;
        try { o = jsonDecode(m.message) as Map<String, dynamic>; } catch (_) { return; }
        switch (o['op']) {
          case 'buy': _payBuy((o['product'] ?? '').toString()); break;
          case 'restore': _payRestore(); break;
          case 'products': _payProducts(); break;
        }
      })
      ..setNavigationDelegate(NavigationDelegate(
        // روابط خارج نطاقنا (wa.me · المتاجر…) تُفتح في تطبيقها: داخل الغلاف تُمنع على iOS (النطاقات المربوطة) ولا تصلح على أندرويد
        onNavigationRequest: (req) {
          final u = Uri.tryParse(req.url);
          if (u == null || !(u.scheme == 'http' || u.scheme == 'https') || kAppHosts.contains(u.host)) {
            return NavigationDecision.navigate;
          }
          if (req.isMainFrame) {
            unawaited(launchUrl(u, mode: LaunchMode.externalApplication).catchError((_) => false));
          }
          return NavigationDecision.prevent;
        },
        onProgress: (p) {
          if (mounted && _loading) setState(() => _progress = p);
        },
        onPageStarted: (_) {
          _watchdog?.cancel();
          // 📴 (٢٩ أكتوبر) الصفحة المحفوظة (عامل الخدمة) تُرسم فورًا بلا نت، لكن «اكتمال التحميل» قد يتأخر بملفٍ خارجي معلّق
          // (شبكة متصلة بلا إنترنت) — فلا تُعرض «ما قدرنا نفتح الصفحة» فوق صفحةٍ ظاهرة: نسألها أولًا هل رُسم التطبيق.
          _watchdog = Timer(const Duration(seconds: 12), () async {
            if (!_loading || !mounted) return;
            var drawn = false;
            try {
              final r = await _web.runJavaScriptReturningResult(
                  "document.querySelector('.scr')?1:0");
              drawn = r.toString() == '1';
            } catch (_) {}
            if (!mounted || !_loading) return;
            if (drawn) {
              setState(() => _loading = false);
              _injectHooks();
            } else {
              _watchdog = Timer(const Duration(seconds: 13), () {
                if (_loading && mounted) setState(() { _offline = true; _loading = false; });
              });
            }
          });
          setState(() { _loading = true; _offline = false; _jsErr = null; _progress = 0; });
        },
        onPageFinished: (_) {
          _watchdog?.cancel();
          _injectHooks();
          setState(() => _loading = false);
        },
        onWebResourceError: (e) {
          // خطأ الإطار الرئيسي فقط = لا نت — أخطاء الموارد الفرعية تُتجاهل
          if (e.isForMainFrame ?? true) {
            _watchdog?.cancel();
            setState(() { _offline = true; _loading = false; });
          }
        },
      ))
      ..loadRequest(Uri.parse(kHome));
  }

  // الجسور تُحقن عند اكتمال الصفحة — أو حين نراها مرسومة قبل ذلك (ملفٌ خارجي معلّق بلا نت). كلها لا تُحقن مرتين (حارس داخلها).
  void _injectHooks() {
    _web.runJavaScript(_errHook);
    _web.runJavaScript(_sttHook);
    _web.runJavaScript(_payHook);
    _web.runJavaScript(_notifHook);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _systemUiRestore?.cancel();
    _watchdog?.cancel();
    _iapSub?.cancel();
    _sttStop();
    super.dispose();
  }

  // 🔙 زر الرجوع في أندرويد: بلا هذا يخرج من التطبيق من أول ضغطة حتى لو كان
  // داخل صفحةٍ فرعية (الدعم · الخصوصية) — وهو عيبٌ يلاحظه مراجع Play فورًا،
  // ويغيظ المستخدم يوميًّا. iOS عنده سحبةُ الحافة فلا يحتاج شيئًا.
  Future<void> _onPop(bool didPop, Object? _) async {
    if (didPop) return;
    if (await _web.canGoBack()) { await _web.goBack(); return; }
    // لا صفحة سابقة: نخرج فعلاً
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: _onPop,
      child: Scaffold(
      backgroundColor: const Color(0xFFF4F7FC),
      // شاشة كاملة بلا أي شريط علوي — الموقع يمتد تحت النتش
      // (viewport-fit=cover موجود في الموقع ويتكفل بمسافات الأمان)
      body: Stack(children: [
          // أندرويد: WebView القديم لا يبلّغ الموقع بمسافات الأمان (env(safe-area-inset-*) = صفر)، فكان المحتوى يدخل تحت
          // الكاميرا وأزرار النظام. نحشوه هنا بالمسافة الفعلية (صفر حين تكون الأشرطة مخفية، وفتحة الكاميرا دائمًا).
          // iOS يبقى كما هو: الموقع يتكفّل بها عبر viewport-fit=cover.
          Platform.isAndroid
              ? SafeArea(child: WebViewWidget.fromPlatformCreationParams(
                  params: AndroidWebViewWidgetCreationParams.fromPlatformWebViewWidgetCreationParams(
                    PlatformWebViewWidgetCreationParams(controller: _web.platform),
                    // Opt-in comparison only; retain the shipping default until device profiling.
                    displayWithHybridComposition: const bool.fromEnvironment('SHATER_ANDROID_HYBRID'),
                  ),
                ))
              : WebViewWidget(controller: _web),
          // 🐱 (فارس ٢٩ أكتوبر: «انميشن في بداية التطبيق بدال مايسوي لودنق طويل») توتي وشريطٌ يمتلئ بتقدّم التحميل الفعلي
          if (_loading) _ShaterLoading(progress: _progress),
          if (_offline)
            Container(
              color: const Color(0xFFF7EFE9),
              alignment: Alignment.center,
              padding: const EdgeInsets.all(28),
              child: Directionality(
                textDirection: TextDirection.rtl,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('📡', style: TextStyle(fontSize: 52)),
                  const SizedBox(height: 12),
                  const Text('ما قدرنا نفتح الصفحة',
                      style: TextStyle(
                          color: Color(0xFF2B1A07),
                          fontSize: 19,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  const Text('تأكد من الإنترنت وجرّب مرة ثانية',
                      style: TextStyle(color: Color(0xFF7A6A58), fontSize: 14)),
                  const SizedBox(height: 20),
                  FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFFF6F1E),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 34, vertical: 14)),
                    onPressed: () => _web.reload(),
                    child: const Text('🔄 أعد المحاولة',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                ]),
              ),
            ),
          // شريط خطأ صغير أسفل الشاشة — يساعد على تصوير المشكلة وإرسالها
          // شريط الأخطاء للتطوير فقط — لا يراه المستخدم ولا مراجع المتجر (الأعطال تصل Sentry)
          if (_jsErr != null && kDebugMode)
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Material(
                color: const Color(0xDDB3261E),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Directionality(
                    textDirection: TextDirection.rtl,
                    child: Row(children: [
                      Expanded(
                        child: Text('⚠️ $_jsErr',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 11.5)),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close,
                            color: Colors.white, size: 18),
                        onPressed: () => setState(() => _jsErr = null),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
      ]),
    ),
    );
  }
}

// 🐱 شاشة الفتح: توتي تتمايل وشريطٌ يمتلئ بتقدّم التحميل — بنفس شاشة «نجهّز لك الجديد» في الموقع (offline_pack.js):
// الأرضية #F4F7FC · الشريط #E9EEF7 والملء #FF6F1E · الحبر #24324B. بلا نصّ: الحركة والشكل يتكلمان.
class _ShaterLoading extends StatefulWidget {
  const _ShaterLoading({required this.progress});
  final int progress;
  @override
  State<_ShaterLoading> createState() => _ShaterLoadingState();
}

class _ShaterLoadingState extends State<_ShaterLoading> with SingleTickerProviderStateMixin {
  late final AnimationController _bob =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();

  @override
  void dispose() {
    _bob.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = (widget.progress.clamp(6, 100)) / 100.0;
    return Container(
      color: const Color(0xFFF4F7FC),
      alignment: Alignment.center,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        AnimatedBuilder(
          animation: _bob,
          builder: (_, child) {
            final t = _bob.value;
            final up = t < .45 ? Curves.easeOut.transform(t / .45) : Curves.easeIn.transform(1 - (t - .45) / .55);
            return SizedBox(
              width: 170,
              height: 184,
              child: Stack(alignment: Alignment.bottomCenter, children: [
                Container(
                  width: 96 - 26 * up,
                  height: 14,
                  decoration: BoxDecoration(
                      color: Color.fromRGBO(36, 50, 75, .10 - .04 * up),
                      borderRadius: const BorderRadius.all(Radius.elliptical(48, 7))),
                ),
                Positioned(
                  bottom: 8 + 12 * up,
                  child: Transform.scale(
                    scaleX: 1 - .02 * up,
                    scaleY: 1 + .02 * up,
                    alignment: Alignment.bottomCenter,
                    child: child,
                  ),
                ),
              ]),
            );
          },
          child: Image.asset('assets/totti.webp', width: 160, height: 160, filterQuality: FilterQuality.medium),
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: 240,
          height: 14,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: Stack(children: [
              Container(color: const Color(0xFFE9EEF7)),
              AnimatedFractionallySizedBox(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
                alignment: AlignmentDirectional.centerStart,
                widthFactor: p,
                child: Container(
                  decoration: BoxDecoration(
                      color: const Color(0xFFFF6F1E), borderRadius: BorderRadius.circular(999)),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
