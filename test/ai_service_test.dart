import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/services/ai_service.dart';

void main() {
  test('recognizes only the NVIDIA hosted API URL', () {
    expect(
      AiService.isNvidiaBaseUrl('https://integrate.api.nvidia.com/v1'),
      isTrue,
    );
    expect(AiService.isNvidiaBaseUrl('https://api.deepseek.com'), isFalse);
  });

  test('NVIDIA model picker keeps only verified free chat models', () {
    final models = AiService.filterNvidiaFreeModels([
      'paid/partner-model',
      'nvidia/nemotron-3-super-120b-a12b',
      'nvidia/embed-qa-4',
      'openai/gpt-oss-20b',
    ]);

    expect(models, ['nvidia/nemotron-3-super-120b-a12b', 'openai/gpt-oss-20b']);
  });

  test('GLM is the default NVIDIA model', () {
    expect(AiService.nvidiaDefaultModel, 'z-ai/glm-5.2');
    expect(AiService.nvidiaFreeChatModels.first, 'z-ai/glm-5.2');
  });

  test('recognizes Google generative language API URLs', () {
    expect(
      AiService.isGoogleBaseUrl('https://generativelanguage.googleapis.com/v1beta/openai/'),
      isTrue,
    );
    expect(
      AiService.isGoogleBaseUrl('https://generativelanguage.googleapis.com/v1beta'),
      isTrue,
    );
    expect(AiService.isGoogleBaseUrl('https://api.deepseek.com'), isFalse);
  });

  test('ranks Pro models before Flash models', () {
    final models = ['gemini-2.0-flash', 'gemini-1.5-pro', 'gemini-2.0-pro-exp-02-05'];
    models.sort(AiService.compareGoogleModels);
    expect(models.first, 'gemini-2.0-pro-exp-02-05');
    expect(models[1], 'gemini-1.5-pro');
    expect(models[2], 'gemini-2.0-flash');
  });
  test('correctly detects models supporting vision', () {
    // Gemini models
    expect(AiService.isVisionSupported('gemini-2.0-flash'), isTrue);
    expect(AiService.isVisionSupported('gemini-1.5-pro'), isTrue);
    expect(AiService.isVisionSupported('google/gemini-2.5-flash'), isTrue);

    // OpenAI multimodal
    expect(AiService.isVisionSupported('gpt-4o'), isTrue);
    expect(AiService.isVisionSupported('gpt-4o-mini'), isTrue);
    expect(AiService.isVisionSupported('gpt-4-turbo'), isTrue);
    expect(AiService.isVisionSupported('o1'), isTrue);

    // Claude multimodal
    expect(AiService.isVisionSupported('claude-3-5-sonnet-20241022'), isTrue);
    expect(AiService.isVisionSupported('claude-3-7-sonnet'), isTrue);
    expect(AiService.isVisionSupported('claude-3-haiku'), isTrue);

    // Open source / OpenRouter vision flags
    expect(AiService.isVisionSupported('qwen/qwen-2-vl-72b-instruct'), isTrue);
    expect(AiService.isVisionSupported('meta-llama/llama-3.2-11b-vision-instruct'), isTrue);
    expect(AiService.isVisionSupported('mistralai/pixtral-12b'), isTrue);

    // Text-only models return false
    expect(AiService.isVisionSupported('deepseek-chat'), isFalse);
    expect(AiService.isVisionSupported('deepseek-coder'), isFalse);
    expect(AiService.isVisionSupported('deepseek-ai/deepseek-v4-flash'), isFalse);
    expect(AiService.isVisionSupported('z-ai/glm-5.2'), isFalse);
    expect(AiService.isVisionSupported('meta/llama-3.3-70b-instruct'), isFalse);
    expect(AiService.isVisionSupported('mistralai/mistral-nemotron'), isFalse);
  });
}