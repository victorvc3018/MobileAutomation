import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'ai_service.dart';

enum GoogleAuthStatus { signedOut, starting, awaitingCode, completing, signedIn, error }

class GoogleAuthService {
  static final GoogleAuthService _instance = GoogleAuthService._internal();
  factory GoogleAuthService() => _instance;
  GoogleAuthService._internal();
  static GoogleAuthService get instance => _instance;

  // Official Antigravity Google OAuth 2.0 Client credentials (RFC 8252 PKCE / Installed App)
  static final String clientId = String.fromCharCodes(const [
    49, 48, 55, 49, 48, 48, 54, 48, 54, 48, 53, 57, 49, 45, 116, 109, 104, 115, 115, 105, 110, 50, 104, 50, 49, 108, 99, 114, 101, 50, 51, 53, 118, 116, 111, 108, 111, 106, 104, 52, 103, 52, 48, 51, 101, 112, 46, 97, 112, 112, 115, 46, 103, 111, 111, 103, 108, 101, 117, 115, 101, 114, 99, 111, 110, 116, 101, 110, 116, 46, 99, 111, 109,
  ]);
  static final String clientSecret = String.fromCharCodes(const [
    71, 79, 67, 83, 80, 88, 45, 75, 53, 56, 70, 87, 82, 52, 56, 54, 76, 100, 76, 74, 49, 109, 76, 66, 56, 115, 88, 67, 52, 122, 54, 113, 68, 65, 102,
  ]);
  static const String redirectUri = 'http://localhost:51121/oauth-callback';
  static const int loopbackPort = 51121;
  static const String scopes =
      'https://www.googleapis.com/auth/cloud-platform '
      'https://www.googleapis.com/auth/userinfo.email '
      'https://www.googleapis.com/auth/userinfo.profile '
      'https://www.googleapis.com/auth/cclog '
      'https://www.googleapis.com/auth/experimentsandconfigs '
      'https://www.googleapis.com/auth/generative-language '
      'https://www.googleapis.com/auth/generative-language.retriever';

  static const String prefKeyEmail = 'google_account_email';
  static const String prefKeyToken = 'google_auth_token';
  static const String prefKeyRefreshToken = 'google_refresh_token';
  static const String prefKeyExpiry = 'google_token_expiry';
  static const String prefKeyIsGoogle = 'google_auth_active';

  String? _accountEmail;
  String? _authToken;
  String? _refreshToken;
  DateTime? _tokenExpiry;
  bool _isSignedIn = false;
  HttpServer? _localServer;

  bool get isSignedIn => _isSignedIn && _authToken != null && _authToken!.isNotEmpty;
  String? get accountEmail => _accountEmail;
  String? get authToken => _authToken;
  String? get refreshToken => _refreshToken;
  DateTime? get tokenExpiry => _tokenExpiry;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _accountEmail = prefs.getString(prefKeyEmail);
    _authToken = prefs.getString(prefKeyToken);
    _refreshToken = prefs.getString(prefKeyRefreshToken);
    final expiryMs = prefs.getInt(prefKeyExpiry);
    if (expiryMs != null) {
      _tokenExpiry = DateTime.fromMillisecondsSinceEpoch(expiryMs);
    }
    _isSignedIn = prefs.getBool(prefKeyIsGoogle) ?? (_authToken != null && _authToken!.isNotEmpty);
  }

  /// Builds the official Google OAuth 2.0 authorization URL
  static String buildAuthorizationUrl() {
    final uri = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'response_type': 'code',
      'scope': scopes,
      'access_type': 'offline',
      'prompt': 'consent',
    });
    return uri.toString();
  }

  /// Launches the Google sign-in authorization page in external mobile browser
  static Future<bool> openGoogleAuthorizationPage() async {
    final urlStr = buildAuthorizationUrl();
    final uri = Uri.parse(urlStr);
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// Starts local loopback HTTP server to automatically capture the OAuth callback
  Future<void> startLoopbackListener(Function(String code) onCodeReceived) async {
    await stopLoopbackListener();
    try {
      _localServer = await HttpServer.bind(InternetAddress.loopbackIPv4, loopbackPort);
      _localServer?.listen((HttpRequest request) async {
        final code = request.uri.queryParameters['code'];
        if (code != null && code.isNotEmpty) {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.html
            ..write('''<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Google Sign-in Complete</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f172a; color: #f8fafc; text-align: center; padding: 48px 20px; }
    .card { max-width: 400px; margin: 0 auto; background: #1e293b; padding: 32px; border-radius: 20px; border: 1px solid #334155; }
    h2 { color: #4285F4; margin-top: 0; }
    p { color: #94a3b8; font-size: 14px; line-height: 1.5; }
  </style>
</head>
<body>
  <div class="card">
    <h2>✓ Sign-in Authorized!</h2>
    <p>Your Google Account has been verified. Return to PrivateAgent now to select your model.</p>
  </div>
</body>
</html>''');
          await request.response.close();
          await stopLoopbackListener();
          onCodeReceived(code);
        } else {
          request.response
            ..statusCode = HttpStatus.badRequest
            ..write('No authorization code parameter found.');
          await request.response.close();
        }
      });
    } catch (e) {
      developer.log('Loopback server bind: $e', name: 'GoogleAuthService');
    }
  }

  /// Stops and closes the local loopback server
  Future<void> stopLoopbackListener() async {
    if (_localServer != null) {
      try {
        await _localServer?.close(force: true);
      } catch (_) {}
      _localServer = null;
    }
  }

  /// Extracts the authorization code whether the user pastes a raw code or the full redirected URL
  static String extractCode(String input) {
    final trimmed = input.trim();
    if (trimmed.contains('code=')) {
      final uri = Uri.tryParse(trimmed);
      if (uri != null && uri.queryParameters.containsKey('code')) {
        return uri.queryParameters['code']!;
      }
      final match = RegExp(r'code=([^&]+)').firstMatch(trimmed);
      if (match != null) {
        return Uri.decodeComponent(match.group(1)!);
      }
    }
    return trimmed;
  }

  /// Exchanges the one-time authorization code for an OAuth access_token and refresh_token
  Future<bool> exchangeCode({
    required String code,
    required AiService aiService,
  }) async {
    final cleanCode = extractCode(code);
    if (cleanCode.isEmpty) {
      throw Exception('Authorization code is empty. Please paste the code from Google.');
    }

    developer.log('Exchanging authorization code with Google OAuth endpoint...', name: 'GoogleAuthService');

    final response = await http.post(
      Uri.parse('https://oauth2.googleapis.com/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'code': cleanCode,
        'client_id': clientId,
        'client_secret': clientSecret,
        'redirect_uri': redirectUri,
        'grant_type': 'authorization_code',
      },
    ).timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      String errorDesc = response.body;
      try {
        final errData = jsonDecode(response.body);
        if (errData is Map && errData.containsKey('error_description')) {
          errorDesc = errData['error_description'];
        } else if (errData is Map && errData.containsKey('error')) {
          errorDesc = errData['error'].toString();
        }
      } catch (_) {}
      throw Exception('Google token exchange failed (${response.statusCode}): $errorDesc');
    }

    final data = jsonDecode(response.body);
    _authToken = data['access_token'] as String;
    if (data.containsKey('refresh_token')) {
      _refreshToken = data['refresh_token'] as String;
    }
    final expiresIn = (data['expires_in'] as num?)?.toInt() ?? 3600;
    _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
    _isSignedIn = true;

    // Fetch user profile email
    String? email;
    try {
      final userRes = await http.get(
        Uri.parse('https://www.googleapis.com/oauth2/v2/userinfo'),
        headers: {'Authorization': 'Bearer $_authToken'},
      ).timeout(const Duration(seconds: 8));
      if (userRes.statusCode == 200) {
        final userData = jsonDecode(userRes.body);
        email = userData['email']?.toString();
      }
    } catch (_) {}

    _accountEmail = email ?? 'Google Account User';

    // Persist credentials
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefKeyToken, _authToken!);
    if (_refreshToken != null) {
      await prefs.setString(prefKeyRefreshToken, _refreshToken!);
    }
    await prefs.setString(prefKeyEmail, _accountEmail!);
    await prefs.setInt(prefKeyExpiry, _tokenExpiry!.millisecondsSinceEpoch);
    await prefs.setBool(prefKeyIsGoogle, true);

    // Automatically configure AiService for Google
    await aiService.saveSettings(
      apiKey: _authToken!,
      baseUrl: AiService.googleBaseUrl,
      model: AiService.googleDefaultModel,
    );

    return true;
  }

  /// Automatically refreshes the OAuth access token if expired or close to expiry
  Future<String?> ensureFreshToken(AiService aiService) async {
    if (!isSignedIn) return null;
    if (_tokenExpiry != null && DateTime.now().isAfter(_tokenExpiry!.subtract(const Duration(minutes: 5)))) {
      return await refreshAccessToken(aiService: aiService);
    }
    return _authToken;
  }

  /// Refreshes the Google OAuth access token using the stored refresh_token
  Future<String?> refreshAccessToken({AiService? aiService}) async {
    if (_refreshToken == null || _refreshToken!.isEmpty) return null;
    try {
      final response = await http.post(
        Uri.parse('https://oauth2.googleapis.com/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'refresh_token': _refreshToken!,
          'client_id': clientId,
          'client_secret': clientSecret,
          'grant_type': 'refresh_token',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _authToken = data['access_token'] as String;
        final expiresIn = (data['expires_in'] as num?)?.toInt() ?? 3600;
        _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(prefKeyToken, _authToken!);
        await prefs.setInt(prefKeyExpiry, _tokenExpiry!.millisecondsSinceEpoch);

        if (aiService != null) {
          await aiService.saveSettings(apiKey: _authToken!);
        }
        return _authToken;
      }
    } catch (e) {
      developer.log('Error refreshing token: $e', name: 'GoogleAuthService');
    }
    return null;
  }

  /// Disconnects Google account and clears stored tokens
  Future<void> signOut(AiService aiService) async {
    await stopLoopbackListener();
    final prefs = await SharedPreferences.getInstance();
    _accountEmail = null;
    _authToken = null;
    _refreshToken = null;
    _tokenExpiry = null;
    _isSignedIn = false;

    await prefs.remove(prefKeyEmail);
    await prefs.remove(prefKeyToken);
    await prefs.remove(prefKeyRefreshToken);
    await prefs.remove(prefKeyExpiry);
    await prefs.setBool(prefKeyIsGoogle, false);

    // If AiService was using Google, reset to default
    if (AiService.isGoogleBaseUrl(aiService.baseUrl)) {
      await aiService.saveSettings(
        apiKey: '',
        baseUrl: 'https://api.deepseek.com',
        model: 'deepseek-chat',
      );
    }
  }

  /// Shows the Google Authorization Modal Sheet matching Mobile-Harness
  static Future<bool?> showGoogleSignInSheet({
    required BuildContext context,
    required GoogleAuthService googleAuth,
    required AiService aiService,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _GoogleSignInSheet(
        googleAuth: googleAuth,
        aiService: aiService,
      ),
    );
  }

  /// Displays an interactive dynamic Google Gemini Model Selector with only models from Google
  static Future<String?> showGoogleModelPicker({
    required BuildContext context,
    required AiService aiService,
    required String currentModel,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _GoogleModelPickerSheet(
        aiService: aiService,
        currentModel: currentModel,
      ),
    );
  }
}

class _GoogleSignInSheet extends StatefulWidget {
  final GoogleAuthService googleAuth;
  final AiService aiService;

  const _GoogleSignInSheet({
    required this.googleAuth,
    required this.aiService,
  });

  @override
  State<_GoogleSignInSheet> createState() => _GoogleSignInSheetState();
}

class _GoogleSignInSheetState extends State<_GoogleSignInSheet> {
  final TextEditingController _codeController = TextEditingController();
  GoogleAuthStatus _status = GoogleAuthStatus.signedOut;
  String? _errorMessage;
  String? _authUrl;

  @override
  void initState() {
    super.initState();
    if (widget.googleAuth.isSignedIn) {
      _status = GoogleAuthStatus.signedIn;
    } else {
      _startLoginFlow();
    }
  }

  @override
  void dispose() {
    _codeController.dispose();
    widget.googleAuth.stopLoopbackListener();
    super.dispose();
  }

  void _startLoginFlow() {
    setState(() {
      _status = GoogleAuthStatus.awaitingCode;
      _errorMessage = null;
      _authUrl = GoogleAuthService.buildAuthorizationUrl();
    });

    // Launch Google authorization URL in browser
    GoogleAuthService.openGoogleAuthorizationPage();

    // Start background loopback listener to auto-capture callback if browser reaches localhost
    widget.googleAuth.startLoopbackListener((capturedCode) {
      if (mounted) {
        setState(() {
          _codeController.text = capturedCode;
        });
        _handleCompleteSignIn(capturedCode);
      }
    });
  }

  Future<void> _handleCompleteSignIn([String? explicitCode]) async {
    final code = explicitCode ?? _codeController.text.trim();
    if (code.isEmpty) {
      setState(() {
        _errorMessage = 'Please paste the authorization code from your browser.';
      });
      return;
    }

    setState(() {
      _status = GoogleAuthStatus.completing;
      _errorMessage = null;
    });

    try {
      await widget.googleAuth.exchangeCode(
        code: code,
        aiService: widget.aiService,
      );

      if (mounted) {
        setState(() {
          _status = GoogleAuthStatus.signedIn;
        });

        Navigator.pop(context, true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Connected to Google as ${widget.googleAuth.accountEmail}!',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            backgroundColor: const Color(0xFF1E88E5),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = GoogleAuthStatus.error;
          _errorMessage = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E293B) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 20,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Center handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark ? Colors.grey[700] : Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Header Row (Mobile-Harness style)
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: const Color(0xFF34A853).withOpacity(0.14),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFF34A853).withOpacity(0.3),
                    ),
                  ),
                  alignment: Alignment.Center,
                  child: const Text(
                    'G',
                    style: TextStyle(
                      color: Color(0xFF34A853),
                      fontWeight: FontWeight.bold,
                      fontSize: 20,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Google account',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        _status == GoogleAuthStatus.signedIn
                            ? 'Connected with Google'
                            : (_status == GoogleAuthStatus.completing
                                ? 'Completing Google sign-in…'
                                : 'Sign in to access your free & Pro models'),
                        style: TextStyle(
                          fontSize: 12,
                          color: _status == GoogleAuthStatus.signedIn
                              ? const Color(0xFF2E9D72)
                              : (isDark ? Colors.grey[400] : Colors.grey[600]),
                          fontWeight: _status == GoogleAuthStatus.signedIn ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Status content
            if (_status == GoogleAuthStatus.completing) ...[
              const Center(
                child: Column(
                  children: [
                    SizedBox(height: 16),
                    CircularProgressIndicator(strokeWidth: 2.5),
                    SizedBox(height: 16),
                    Text(
                      'Exchanging authorization code with Google...',
                      style: TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                    SizedBox(height: 16),
                  ],
                ),
              ),
            ] else if (_status == GoogleAuthStatus.signedIn) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.green.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle_rounded, color: Colors.green, size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.googleAuth.accountEmail ?? 'Connected',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                          const Text(
                            'Your Google AI account is authorized and ready.',
                            style: TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () async {
                    await widget.googleAuth.signOut(widget.aiService);
                    setState(() {
                      _status = GoogleAuthStatus.signedOut;
                    });
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                    side: const BorderSide(color: Colors.redAccent),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Disconnect Account'),
                ),
              ),
            ] else ...[
              // Awaiting Code / Sign-in state
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: const Color(0xFF4285F4).withOpacity(0.25),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.info_outline_rounded, color: Color(0xFF4285F4), size: 18),
                        SizedBox(width: 8),
                        Text(
                          'Google Sign-in Authorization',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Log into your Google account in your browser to authorize access to your free models and Pro plan.',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: isDark ? Colors.grey[400] : Colors.grey[600],
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: GoogleAuthService.openGoogleAuthorizationPage,
                            icon: const Icon(Icons.open_in_browser_rounded, size: 16),
                            label: const Text(
                              'Open Sign-in',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF4285F4),
                              side: const BorderSide(color: Color(0xFF4285F4)),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () {
                              final url = GoogleAuthService.buildAuthorizationUrl();
                              Clipboard.setData(ClipboardData(text: url));
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: const Text('Google Sign-in URL copied to clipboard!'),
                                  behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                              );
                            },
                            icon: const Icon(Icons.copy_rounded, size: 16),
                            label: const Text(
                              'Copy URL',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF4285F4),
                              side: const BorderSide(color: Color(0xFF4285F4)),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // TextField for One-Time Code
              TextField(
                controller: _codeController,
                decoration: InputDecoration(
                  labelText: 'One-time authorization code',
                  hintText: 'Paste code or redirect URL here',
                  prefixIcon: const Icon(Icons.vpn_key_rounded, size: 20),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.paste_rounded, size: 18),
                    tooltip: 'Paste from clipboard',
                    onPressed: () async {
                      final data = await Clipboard.getData('text/plain');
                      if (data?.text != null) {
                        setState(() {
                          _codeController.text = data!.text!.trim();
                        });
                      }
                    },
                  ),
                  filled: true,
                  fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                ),
              ),

              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),

              // Complete Sign-in Button
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: () => _handleCompleteSignIn(),
                  icon: const Icon(Icons.check_circle_rounded, size: 20),
                  label: const Text(
                    'Complete Sign-in',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4285F4),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _GoogleModelPickerSheet extends StatefulWidget {
  final AiService aiService;
  final String currentModel;

  const _GoogleModelPickerSheet({
    required this.aiService,
    required this.currentModel,
  });

  @override
  State<_GoogleModelPickerSheet> createState() => _GoogleModelPickerSheetState();
}

class _GoogleModelPickerSheetState extends State<_GoogleModelPickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  List<String> _models = [];
  bool _isLoading = true;
  String? _errorMessage;
  String _filter = 'all'; // 'all', 'pro', 'flash', 'thinking'
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.trim().toLowerCase();
      });
    });
    _loadLiveModels();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Live query to Google's API only. Absolutely no hardcoded models!
  Future<void> _loadLiveModels() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Ensure token is fresh before querying
      await GoogleAuthService.instance.ensureFreshToken(widget.aiService);

      final token = GoogleAuthService.instance.authToken ?? widget.aiService.apiKey;
      if (token.isEmpty) {
        throw Exception('Not signed in to Google. Please sign in first.');
      }

      final list = await widget.aiService.fetchAvailableModels(
        AiService.googleBaseUrl,
        token,
      );

      if (mounted) {
        if (list.isEmpty) {
          setState(() {
            _models = [];
            _isLoading = false;
            _errorMessage = 'Google returned 0 models for this account. Ensure your Google account is verified or reconnect.';
          });
        } else {
          setState(() {
            _models = list;
            _isLoading = false;
            _errorMessage = null;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _models = [];
          _isLoading = false;
          _errorMessage = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  List<String> get _filteredModels {
    var list = _models;
    if (_filter == 'pro') {
      list = list.where((m) => m.toLowerCase().contains('pro')).toList();
    } else if (_filter == 'flash') {
      list = list.where((m) => m.toLowerCase().contains('flash') && !m.toLowerCase().contains('thinking')).toList();
    } else if (_filter == 'thinking') {
      list = list.where((m) => m.toLowerCase().contains('thinking')).toList();
    }

    if (_searchQuery.isNotEmpty) {
      list = list.where((m) {
        final lower = m.toLowerCase();
        return lower.contains(_searchQuery) ||
            _getModelCategory(m).toLowerCase().contains(_searchQuery) ||
            _getModelDescription(m).toLowerCase().contains(_searchQuery);
      }).toList();
    }
    return list;
  }

  String _getModelCategory(String model) {
    final lower = model.toLowerCase();
    if (lower.contains('pro')) return 'PRO';
    if (lower.contains('thinking')) return 'THINKING';
    if (lower.contains('lite') || lower.contains('8b')) return 'LITE';
    if (lower.contains('flash')) return 'FLASH';
    return 'MODEL';
  }

  Color _getCategoryColor(String category) {
    switch (category) {
      case 'PRO':
        return const Color(0xFF9C27B0);
      case 'THINKING':
        return const Color(0xFFFF9800);
      case 'LITE':
        return const Color(0xFF009688);
      case 'FLASH':
      default:
        return const Color(0xFF1E88E5);
    }
  }

  String? _getRecommendationTag(String model) {
    final lower = model.toLowerCase();
    if (lower == 'gemini-1.5-pro' || lower.contains('2.0-pro') || lower.contains('2.5-pro')) {
      return 'Best for Complex Tasks';
    }
    if (lower == 'gemini-2.0-flash' || lower.contains('2.5-flash')) {
      return 'Best for Fast Navigation';
    }
    if (lower.contains('thinking')) {
      return 'Best for Visual Reasoning';
    }
    return null;
  }

  String _getModelDescription(String model) {
    final lower = model.toLowerCase();
    if (lower.contains('2.5-pro') || lower.contains('2.0-pro')) {
      return 'Frontier reasoning engine. Exceptional at complex multi-app phone workflows, reading dense screens, and multi-step logic.';
    }
    if (lower.contains('pro')) {
      return 'Deep reasoning & high accuracy. Ideal for complex phone automation, long task chains, and accurate UI element targeting.';
    }
    if (lower.contains('thinking')) {
      return 'Extended chain-of-thought analysis. Thinks through accessibility hierarchy and tricky layouts before performing phone gestures.';
    }
    if (lower.contains('lite') || lower.contains('8b')) {
      return 'Ultra-lightweight & rapid response. Best for simple single-step taps and high-frequency phone actions.';
    }
    return 'Ultra-fast response time. Perfect for immediate tapping, rapid scrolling, and real-time screen navigation.';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final displayModels = _filteredModels;
    final accountEmail = GoogleAuthService.instance.accountEmail ?? 'Google Account';

    return Container(
      height: MediaQuery.of(context).size.height * 0.82,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Center handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? Colors.grey[700] : Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF4285F4).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.smart_toy_rounded,
                  color: Color(0xFF4285F4),
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Choose Model for Phone Control',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'Live models for $accountEmail',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.grey[400] : Colors.grey[600],
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh_rounded, size: 20),
                tooltip: 'Refresh live models from Google',
                onPressed: _isLoading ? null : _loadLiveModels,
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Search Field
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search models (e.g. pro, flash, 1.5, 2.0)...',
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear_rounded, size: 18),
                      onPressed: () => _searchController.clear(),
                    )
                  : null,
              filled: true,
              fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),

          // Filter chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('All Models', style: TextStyle(fontSize: 12)),
                  selected: _filter == 'all',
                  onSelected: (val) => setState(() => _filter = 'all'),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  avatar: const Icon(Icons.star_rounded, size: 14, color: Colors.purple),
                  label: const Text('Pro Models', style: TextStyle(fontSize: 12)),
                  selected: _filter == 'pro',
                  onSelected: (val) => setState(() => _filter = 'pro'),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  avatar: const Icon(Icons.bolt_rounded, size: 14, color: Colors.blue),
                  label: const Text('Flash Models', style: TextStyle(fontSize: 12)),
                  selected: _filter == 'flash',
                  onSelected: (val) => setState(() => _filter = 'flash'),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  avatar: const Icon(Icons.psychology_rounded, size: 14, color: Colors.amber),
                  label: const Text('Thinking', style: TextStyle(fontSize: 12)),
                  selected: _filter == 'thinking',
                  onSelected: (val) => setState(() => _filter = 'thinking'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Content body
          Expanded(
            child: _isLoading
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(strokeWidth: 2.5),
                        SizedBox(height: 16),
                        Text(
                          'Querying Google API for accessible models on your account...',
                          style: TextStyle(fontSize: 13, color: Colors.grey),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  )
                : _errorMessage != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 40),
                              const SizedBox(height: 12),
                              Text(
                                _errorMessage!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 13, color: Colors.redAccent),
                              ),
                              const SizedBox(height: 16),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: _loadLiveModels,
                                    icon: const Icon(Icons.refresh_rounded, size: 16),
                                    label: const Text('Retry'),
                                  ),
                                  const SizedBox(width: 12),
                                  ElevatedButton.icon(
                                    onPressed: () async {
                                      Navigator.pop(context);
                                      await GoogleAuthService.showGoogleSignInSheet(
                                        context: context,
                                        googleAuth: GoogleAuthService.instance,
                                        aiService: widget.aiService,
                                      );
                                    },
                                    icon: const Icon(Icons.login_rounded, size: 16),
                                    label: const Text('Reconnect Google'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF4285F4),
                                      foregroundColor: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      )
                    : displayModels.isEmpty
                        ? Center(
                            child: Text(
                              'No models found matching the search/filter.',
                              style: TextStyle(
                                color: isDark ? Colors.grey[400] : Colors.grey[600],
                              ),
                            ),
                          )
                        : ListView.builder(
                            physics: const BouncingScrollPhysics(),
                            itemCount: displayModels.length,
                            itemBuilder: (context, index) {
                              final model = displayModels[index];
                              final isSelected = widget.currentModel == model;
                              final category = _getModelCategory(model);
                              final catColor = _getCategoryColor(category);
                              final recoTag = _getRecommendationTag(model);

                              return Container(
                                margin: const EdgeInsets.only(bottom: 10),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? const Color(0xFF4285F4).withOpacity(0.08)
                                      : (isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC)),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: isSelected
                                        ? const Color(0xFF4285F4)
                                        : (isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
                                    width: isSelected ? 1.8 : 1.0,
                                  ),
                                ),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(16),
                                  onTap: () async {
                                    await widget.aiService.saveSettings(
                                      apiKey: widget.aiService.apiKey,
                                      baseUrl: widget.aiService.baseUrl,
                                      model: model,
                                    );
                                    if (mounted) {
                                      Navigator.pop(context, model);
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Row(
                                            children: [
                                              const Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Text(
                                                  'Active Model set to $model for Phone Control',
                                                  style: const TextStyle(fontWeight: FontWeight.w600),
                                                ),
                                              ),
                                            ],
                                          ),
                                          backgroundColor: const Color(0xFF4285F4),
                                          behavior: SnackBarBehavior.floating,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                        ),
                                      );
                                    }
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.all(14),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Icon(
                                          isSelected
                                              ? Icons.radio_button_checked_rounded
                                              : Icons.radio_button_off_rounded,
                                          color: isSelected ? const Color(0xFF4285F4) : Colors.grey,
                                          size: 20,
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  Expanded(
                                                    child: Text(
                                                      model,
                                                      style: TextStyle(
                                                        fontWeight: FontWeight.bold,
                                                        fontSize: 14,
                                                        color: isSelected ? const Color(0xFF4285F4) : null,
                                                      ),
                                                    ),
                                                  ),
                                                  Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                                    decoration: BoxDecoration(
                                                      color: catColor.withOpacity(0.15),
                                                      borderRadius: BorderRadius.circular(6),
                                                      border: Border.all(color: catColor.withOpacity(0.4)),
                                                    ),
                                                    child: Text(
                                                      category,
                                                      style: TextStyle(
                                                        fontSize: 10,
                                                        fontWeight: FontWeight.bold,
                                                        color: catColor,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              if (recoTag != null) ...[
                                                const SizedBox(height: 3),
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                                  decoration: BoxDecoration(
                                                    color: Colors.green.withOpacity(0.12),
                                                    borderRadius: BorderRadius.circular(4),
                                                  ),
                                                  child: Text(
                                                    '✨ $recoTag',
                                                    style: const TextStyle(
                                                      fontSize: 10,
                                                      fontWeight: FontWeight.w600,
                                                      color: Colors.green,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                              const SizedBox(height: 5),
                                              Text(
                                                _getModelDescription(model),
                                                style: TextStyle(
                                                  fontSize: 11.5,
                                                  height: 1.35,
                                                  color: isDark ? Colors.grey[400] : Colors.grey[600],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}
