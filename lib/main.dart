// ═══════════════════════════════════════════════════════════════════════════
// شاطر — غلاف iOS/أندرويد للموقع (WebView)
//
// كل المنتج يعيش في shater-web.vercel.app — هذا الغلاف نافذة له فقط.
// الفائدة: أيقونة بالمتجر + TestFlight، وأي نشرة ويب توصل فورًا بلا بناء.
//
// ⚠️ أهم سطرين في الملف كله: تشغيل الصوت بلا لمسة من المستخدم
// (allowsInlineMediaPlayback + mediaTypesRequiringUserAction: none) —
// بلاهما صوت مريم لا يشتغل تلقائيًا داخل WebView على iOS، وهو قلب المنتج.
// ═══════════════════════════════════════════════════════════════════════════
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

const String kHome = 'https://shater-web.vercel.app/';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const ShaterApp());
}

class ShaterApp extends StatelessWidget {
  const ShaterApp({super.key});
  @override
  Widget build(BuildContext context) => const MaterialApp(
        title: 'شاطر',
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
      ..setBackgroundColor(const Color(0xFF150A2E)) // خلفية شاطر — لا وميض أبيض
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
    _sttStop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF150A2E),
      // شاشة كاملة بلا أي شريط علوي — الموقع يمتد تحت النتش
      // (viewport-fit=cover موجود في الموقع ويتكفل بمسافات الأمان)
      body: Stack(children: [
          WebViewWidget(controller: _web),
          if (_loading)
            const Center(
              child: CircularProgressIndicator(color: Color(0xFFFFD24A)),
            ),
          if (_offline)
            Container(
              color: const Color(0xFF150A2E),
              alignment: Alignment.center,
              padding: const EdgeInsets.all(28),
              child: Directionality(
                textDirection: TextDirection.rtl,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('📡', style: TextStyle(fontSize: 52)),
                  const SizedBox(height: 12),
                  const Text('ما قدرنا نفتح الصفحة',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 19,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  const Text('تأكد من الإنترنت وجرّب مرة ثانية',
                      style: TextStyle(color: Colors.white70, fontSize: 14)),
                  const SizedBox(height: 20),
                  FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFFFD24A),
                        foregroundColor: const Color(0xFF150A2E),
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
          if (_jsErr != null)
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
