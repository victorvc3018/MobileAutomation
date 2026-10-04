import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/main.dart';
import 'package:private_agent/screens/home_screen.dart';
import 'package:private_agent/services/ai_service.dart';
import 'package:private_agent/services/action_handler.dart';
import 'package:private_agent/services/task_executor.dart';
import 'package:private_agent/services/voice_service.dart';

void main() {
  test('App components compile and link correctly', () {
    expect(AiService.isVisionSupported('gemini-2.0-flash'), isTrue);
    expect(AiService.isVisionSupported('deepseek-chat'), isFalse);
    expect(AiService.isVisionSupported('gpt-4o'), isTrue);
    expect(AiService.isVisionSupported('claude-3-7-sonnet'), isTrue);
  });
}