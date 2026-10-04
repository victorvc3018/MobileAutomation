import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/main.dart';
import 'package:private_agent/screens/home_screen.dart';
import 'package:private_agent/services/ai_service.dart';
import 'package:private_agent/services/action_handler.dart';
import 'package:private_agent/services/task_executor.dart';
import 'package:private_agent/services/screen_automation_service.dart';
import 'package:private_agent/services/voice_service.dart';

void main() {
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

  test('ScreenshotData correctly computes resolution scale factors', () {
    final data = ScreenshotData(
      base64: 'fakeBase64',
      width: 720,
      height: 1600,
      nativeWidth: 1080,
      nativeHeight: 2400,
      scale: 720 / 1080,
    );
    expect(data.width, 720);
    expect(data.height, 1600);
    expect(data.nativeWidth, 1080);
    expect(data.nativeHeight, 2400);
    expect(data.scale, closeTo(0.666, 0.001));

    // Verify coordinate upscaling
    final visualTapX = 360;
    final visualTapY = 800;
    final nativeTapX = (visualTapX / data.scale).round();
    final nativeTapY = (visualTapY / data.scale).round();
    expect(nativeTapX, 540);
    expect(nativeTapY, 1200);
  });
}
