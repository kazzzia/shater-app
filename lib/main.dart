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
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

const String kHome = 'https://shater-web.vercel.app/hub';

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
    _web
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF1E2A47)) // خلفية شاطر — لا وميض أبيض
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => setState(() { _loading = true; _offline = false; }),
        onPageFinished: (_) => setState(() => _loading = false),
        onWebResourceError: (e) {
          // خطأ الإطار الرئيسي فقط = لا نت — أخطاء الموارد الفرعية تُتجاهل
          if (e.isForMainFrame ?? true) {
            setState(() { _offline = true; _loading = false; });
          }
        },
      ))
      ..loadRequest(Uri.parse(kHome));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E2A47),
      body: SafeArea(
        // الموقع نفسه يتعامل مع النتش (viewport-fit=cover) — لكن SafeArea
        // العلوية تمنع تداخل الساعة مع أزرار التطبيق أول فتحة
        bottom: false,
        child: Stack(children: [
          WebViewWidget(controller: _web),
          if (_loading)
            const Center(
              child: CircularProgressIndicator(color: Color(0xFFFFD24A)),
            ),
          if (_offline)
            Container(
              color: const Color(0xFF1E2A47),
              alignment: Alignment.center,
              padding: const EdgeInsets.all(28),
              child: Directionality(
                textDirection: TextDirection.rtl,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('📡', style: TextStyle(fontSize: 52)),
                  const SizedBox(height: 12),
                  const Text('ما فيه اتصال بالإنترنت',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 19,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  const Text('شاطر يحتاج نت — تأكد من الاتصال وجرّب',
                      style: TextStyle(color: Colors.white70, fontSize: 14)),
                  const SizedBox(height: 20),
                  FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFFFD24A),
                        foregroundColor: const Color(0xFF1E2A47),
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
        ]),
      ),
    );
  }
}
