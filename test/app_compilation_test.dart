import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:private_agent/services/ai_service.dart';
import 'package:private_agent/services/task_executor.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('App components compile and link correctly', () {
    expect(AiService.isVisionSupported('gemini-2.0-flash'), isTrue);
    expect(AiService.isVisionSupported('deepseek-chat'), isFalse);
    expect(AiService.isVisionSupported('z-ai/glm-5.2'), isFalse);
    expect(AiService.isVisionSupported('meta/llama-3.3-70b-instruct'), isFalse);
    expect(AiService.isVisionSupported('gpt-4o'), isTrue);
    expect(AiService.isVisionSupported('claude-3-7-sonnet'), isTrue);
    expect(AiService.isVisionSupported('stealth/space-bunny-alpha'), isTrue);

    // Goal visual requirement detection
    expect(TaskExecutor.taskRequiresVision("what's on my screen right now?"), isTrue);
    expect(TaskExecutor.taskRequiresVision("look at this picture and tell me what you see"), isTrue);
    expect(TaskExecutor.taskRequiresVision("inspect screen to see if icon is red"), isTrue);
    expect(TaskExecutor.taskRequiresVision("turn on wifi in settings"), isFalse);
  });

  test('Vision cannot be enabled for models that do not support it', () async {
    final ai = AiService();
    await ai.init();

    // Default model is deepseek-chat (text-only)
    expect(AiService.isVisionSupported(ai.model), isFalse);

    // Attempting to set vision enabled on text-only model should reject it
    await ai.setVisionEnabled(true);
    expect(ai.isVisionEnabled, isFalse);
  });
}
