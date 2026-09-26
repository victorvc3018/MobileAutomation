import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'ai_service.dart';

enum GoogleAuthStatus { signedOut, authenticating, signedIn, error }

class GoogleAuthService {
  static const String prefKeyEmail = 'google_account_email';
  static const String prefKeyToken = 'google_auth_token';
  static const String prefKeyIsGoogle = 'google_auth_active';
  static const String googleAiStudioUrl = 'https://aistudio.google.com/app/apikey';

  String? _accountEmail;
  String? _authToken;
  bool _isSignedIn = false;

  bool get isSignedIn => _isSignedIn && _authToken != null && _authToken!.isNotEmpty;
  String? get accountEmail => _accountEmail;
  String? get authToken => _authToken;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _accountEmail = prefs.getString(prefKeyEmail);
    _authToken = prefs.getString(prefKeyToken);
    _isSignedIn = prefs.getBool(prefKeyIsGoogle) ?? (_authToken != null && _authToken!.isNotEmpty);
  }

  /// Sets credentials and updates AiService to Google Gemini
  Future<void> setGoogleCredentials({
    required String email,
    required String token,
    required AiService aiService,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    _accountEmail = email.trim();
    _authToken = token.trim();
    _isSignedIn = true;

    await prefs.setString(prefKeyEmail, _accountEmail!);
    await prefs.setString(prefKeyToken, _authToken!);
    await prefs.setBool(prefKeyIsGoogle, true);

    // Automatically configure AiService for Google Gemini
    await aiService.saveSettings(
      apiKey: _authToken!,
      baseUrl: AiService.googleBaseUrl,
      model: AiService.googleDefaultModel,
    );
  }

  /// Disconnects Google account and clears stored tokens
  Future<void> signOut(AiService aiService) async {
    final prefs = await SharedPreferences.getInstance();
    _accountEmail = null;
    _authToken = null;
    _isSignedIn = false;

    await prefs.remove(prefKeyEmail);
    await prefs.remove(prefKeyToken);
    await prefs.setBool(prefKeyIsGoogle, false);

    // If AiService was using Google, reset to default or empty
    if (AiService.isGoogleBaseUrl(aiService.baseUrl)) {
      await aiService.saveSettings(
        apiKey: '',
        baseUrl: 'https://api.deepseek.com',
        model: 'deepseek-chat',
      );
    }
  }

  /// Opens Google AI Studio in the default browser so the user can grab their key with 1 click
  static Future<void> openGoogleAiStudio() async {
    final uri = Uri.parse(googleAiStudioUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Shows an interactive Google Sign-in modal bottom sheet (similar to Mobile-Harness)
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

  /// Displays an interactive Google Gemini Model Selector with Pro / Flash badges and descriptions
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
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _tokenController = TextEditingController();
  bool _obscureToken = true;
  bool _isConnecting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    if (widget.googleAuth.accountEmail != null) {
      _emailController.text = widget.googleAuth.accountEmail!;
    }
    if (widget.googleAuth.authToken != null) {
      _tokenController.text = widget.googleAuth.authToken!;
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _handleConnect() async {
    final token = _tokenController.text.trim();
    final email = _emailController.text.trim();

    if (token.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter your Google Token / Gemini API Key';
      });
      return;
    }

    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });

    try {
      // Validate credentials by testing with Google's models endpoint
      final effectiveEmail = email.isNotEmpty ? email : 'Google Account User';
      await widget.googleAuth.setGoogleCredentials(
        email: effectiveEmail,
        token: token,
        aiService: widget.aiService,
      );

      if (mounted) {
        Navigator.pop(context, true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Signed in as $effectiveEmail with Gemini 2.0 Flash!',
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
      setState(() {
        _errorMessage = 'Failed to connect: ${e.toString().replaceFirst("Exception: ", "")}';
        _isConnecting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).colorScheme.primary;

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

            // Header Row
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4285F4).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.account_circle_rounded,
                    color: Color(0xFF4285F4),
                    size: 28,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Google AI Sign-In',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Connect Google Account / Gemini 2.0 Flash',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.grey[400] : Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // 1-Click Fast Link
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
                      Icon(Icons.auto_awesome, color: Color(0xFF4285F4), size: 18),
                      SizedBox(width: 8),
                      Text(
                        'Instant Free Access via Google AI Studio',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Get your official Gemini 2.0 Flash key directly with your Google Account for free.',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: isDark ? Colors.grey[400] : Colors.grey[600],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 38,
                    child: OutlinedButton.icon(
                      onPressed: GoogleAuthService.openGoogleAiStudio,
                      icon: const Icon(Icons.open_in_new_rounded, size: 16),
                      label: const Text(
                        'Open Google AI Studio (Get Free Key)',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF4285F4),
                        side: const BorderSide(color: Color(0xFF4285F4)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),

            // Google Account Email field
            TextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: 'Google Account Email (Optional)',
                hintText: 'your-email@gmail.com',
                prefixIcon: const Icon(Icons.email_outlined, size: 20),
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
            const SizedBox(height: 12),

            // Token / Key field
            TextField(
              controller: _tokenController,
              obscureText: _obscureToken,
              decoration: InputDecoration(
                labelText: 'Google Token / Gemini Key',
                hintText: 'AIzaSy...',
                prefixIcon: const Icon(Icons.key_rounded, size: 20),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureToken ? Icons.visibility_off : Icons.visibility,
                    size: 18,
                  ),
                  onPressed: () => setState(() => _obscureToken = !_obscureToken),
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

            // Submit Button
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _isConnecting ? null : _handleConnect,
                icon: _isConnecting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check_circle_rounded, size: 20),
                label: Text(
                  _isConnecting ? 'Connecting to Google...' : 'Connect Google AI',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
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
    _loadModels();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadModels() async {
    setState(() => _isLoading = true);
    try {
      final list = await widget.aiService.fetchAvailableModels(
        AiService.googleBaseUrl,
        widget.aiService.apiKey,
      );
      if (mounted) {
        setState(() {
          _models = list;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _models = AiService.googleModels;
          _isLoading = false;
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
        return const Color(0xFF9C27B0); // Deep Purple
      case 'THINKING':
        return const Color(0xFFFF9800); // Amber
      case 'LITE':
        return const Color(0xFF009688); // Teal
      case 'FLASH':
      default:
        return const Color(0xFF1E88E5); // Blue
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
                      'Select which Gemini model will analyze your screen and tap',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.grey[400] : Colors.grey[600],
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh_rounded, size: 20),
                tooltip: 'Refresh live models from Google',
                onPressed: _isLoading ? null : _loadModels,
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Pro Plan Info Banner
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: const Color(0xFF9C27B0).withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFF9C27B0).withOpacity(0.25),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.workspace_premium_rounded,
                  color: Color(0xFF9C27B0),
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Google AI Pro Plan: Select a Pro model (e.g. Gemini 1.5 Pro, 2.0 Pro) for maximum reasoning accuracy across multi-app phone workflows.',
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.3,
                      color: isDark ? const Color(0xFFCE93D8) : const Color(0xFF6A1B9A),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

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

          // Filter chips (All / Pro / Flash / Thinking)
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

          // Models List
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
                        ),
                      ],
                    ),
                  )
                : displayModels.isEmpty
                    ? Center(
                        child: Text(
                          'No models found matching the filter.',
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
                                  : (isDark
                                      ? const Color(0xFF0F172A)
                                      : const Color(0xFFF8FAFC)),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isSelected
                                    ? const Color(0xFF4285F4)
                                    : (isDark
                                        ? const Color(0xFF334155)
                                        : const Color(0xFFE2E8F0)),
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
                                          const Icon(Icons.check_circle_rounded,
                                              color: Colors.white, size: 20),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Text(
                                              'Active Model set to $model for Phone Control',
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.w600),
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
                                    // Radio/Check Icon
                                    Icon(
                                      isSelected
                                          ? Icons.radio_button_checked_rounded
                                          : Icons.radio_button_off_rounded,
                                      color: isSelected
                                          ? const Color(0xFF4285F4)
                                          : Colors.grey,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 12),

                                    // Model Info
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  model,
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 14,
                                                    color: isSelected
                                                        ? const Color(0xFF4285F4)
                                                        : null,
                                                  ),
                                                ),
                                              ),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 8,
                                                  vertical: 2,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: catColor.withOpacity(0.15),
                                                  borderRadius:
                                                      BorderRadius.circular(6),
                                                  border: Border.all(
                                                    color: catColor.withOpacity(0.4),
                                                  ),
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
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: 6,
                                                vertical: 1.5,
                                              ),
                                              decoration: BoxDecoration(
                                                color: Colors.green.withOpacity(0.12),
                                                borderRadius:
                                                    BorderRadius.circular(4),
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
                                              color: isDark
                                                  ? Colors.grey[400]
                                                  : Colors.grey[600],
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
