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
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

// ?native=ios|android: الموقع يعرف أنه داخل التطبيق (دفع المتاجر · إخفاء ما لا يُسمح به داخل التطبيقات)
final String kHome = 'https://shatarah.sa/app?native=${Platform.isIOS ? 'ios' : 'android'}';

// 🍎 معرّفات منتجات الاشتراك — نفسها في App Store Connect وGoogle Play.
// أي منتج جديد يُضاف هنا وفي api/_iap.js (PRODUCTS) معًا، وإلا رفضه الخادم.
const Set<String> kProductIds = {'sa.shatarah.monthly', 'sa.shatarah.yearly'};

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // StoreKit 2 هو الافتراضي في in_app_purchase_storekit 0.4+: المعاملة تصل
  // موقَّعة (JWS) فيتحقّق منها خادمنا بلا مفتاح سرّي. لا نستدعي enableStoreKit2
  // (صارت مهجورة) — لكن لو رجعت الحزمة يومًا إلى StoreKit 1 فسيتغيّر شكل
  // serverVerificationData إلى إيصال، وسيرفضه api/_iap.js برمز jws-shape.
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
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

class _ShaterShellState extends State<ShaterShell> {
  late final WebViewController _web;
  bool _loading = true;
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
if(window.ShaterNotif&&!window.ShaterNotif.set){
window.ShaterNotif.ask=function(){window.ShaterNotif.postMessage(JSON.stringify({op:'ask'}));};
window.ShaterNotif.set=function(items){window.ShaterNotif.postMessage(JSON.stringify({op:'set',items:items||[]}));};
window.ShaterNotif.clear=function(){window.ShaterNotif.postMessage(JSON.stringify({op:'clear'}));};
window.ShaterNotif.native=true;
try{if(window.__shNotifReady)window.__shNotifReady();}catch(_){}
}''';

  final FlutterLocalNotificationsPlugin _fln = FlutterLocalNotificationsPlugin();
  bool _notifReady = false;

  Future<void> _notifInit() async {
    if (_notifReady) return;
    tzdata.initializeTimeZones();
    // ساعة الرياض هي ساعة أهلنا؛ ولو كان الجهاز في بلدٍ آخر فساعته أصدق له.
    try {
      tz.setLocalLocation(tz.getLocation('Asia/Riyadh'));
    } catch (_) {}
    await _fln.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false),
    ));
    _notifReady = true;
  }

  Future<void> _notifAsk() async {
    await _notifInit();
    try {
      if (Platform.isIOS) {
        await _fln
            .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, badge: true, sound: true);
      } else {
        await _fln
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      }
    } catch (_) {}
  }

  static const NotificationDetails _notifStyle = NotificationDetails(
    android: AndroidNotificationDetails('shatarah_daily', 'تذكيرات شطارة',
        channelDescription: 'تذكير المذاكرة وتنبيه الأهل وموعد الاختبار',
        importance: Importance.defaultImportance, priority: Priority.defaultPriority),
    iOS: DarwinNotificationDetails(),
  );

  Future<void> _notifSet(List<dynamic> items) async {
    await _notifInit();
    try { await _fln.cancelAll(); } catch (_) {}
    final now = DateTime.now();
    for (final raw in items) {
      if (raw is! Map) continue;
      final at = DateTime.tryParse('${raw['at']}');
      if (at == null || !at.isAfter(now)) continue;   // ماضٍ: لا يُجدول
      final id = int.tryParse('${raw['id']}') ?? at.millisecondsSinceEpoch ~/ 60000 % 100000;
      try {
        await _fln.zonedSchedule(
          id,
          '${raw['title'] ?? 'شطارة'}',
          '${raw['body'] ?? ''}',
          tz.TZDateTime.from(at, tz.local),
          _notifStyle,
          // غير مضبوط بالثانية عمدًا: الضبط الدقيق يتطلب إذن SCHEDULE_EXACT_ALARM
          // وتبرّره لجوجل، وتذكيرٌ مذاكرةٍ لا يستحق ذلك.
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          // الزمن المرسَل زمنٌ محليّ مطلق (لا جدار ساعة متكرّر) — فهذا هو التفسير الصحيح
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
        );
      } catch (_) {}
    }
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
    // ⚠️ إعدادات المنصة قبل الإنشاء — الصوت التلقائي على iOS يتقرر هنا
    // ولا يمكن تفعيله بعد إنشاء المتحكم
    late final PlatformWebViewControllerCreationParams params;
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
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
    _web
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFF7EFE9)) // خلفية شاطر — لا وميض أبيض
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
        switch (o['op']) {
          case 'ask': _notifAsk(); break;
          case 'set': _notifSet((o['items'] as List?) ?? const []); break;
          case 'clear': _notifInit().then((_) => _fln.cancelAll()); break;
        }
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
        onPageStarted: (_) {
          _watchdog?.cancel();
          _watchdog = Timer(const Duration(seconds: 25), () {
            if (_loading && mounted) {
              setState(() { _offline = true; _loading = false; });
            }
          });
          setState(() { _loading = true; _offline = false; _jsErr = null; });
        },
        onPageFinished: (_) {
          _watchdog?.cancel();
          _web.runJavaScript(_errHook);
          _web.runJavaScript(_sttHook);
          _web.runJavaScript(_payHook);
          _web.runJavaScript(_notifHook);
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

  @override
  void dispose() {
    _watchdog?.cancel();
    _iapSub?.cancel();
    _sttStop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7EFE9),
      // شاشة كاملة بلا أي شريط علوي — الموقع يمتد تحت النتش
      // (viewport-fit=cover موجود في الموقع ويتكفل بمسافات الأمان)
      body: Stack(children: [
          WebViewWidget(controller: _web),
          if (_loading)
            const Center(
              child: CircularProgressIndicator(color: Color(0xFFFF6F1E)),
            ),
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
    );
  }
}
