import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';

class SttService {
  final SpeechToText _speech = SpeechToText();
  bool _isInitialized = false;

  bool get isListening => _speech.isListening;

  Future<bool> _ensureInitialized() async {
    if (_isInitialized) return true;

    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) return false;

    _isInitialized = await _speech.initialize(
      onError: (error) => stopListening(),
    );
    return _isInitialized;
  }

  Future<bool> startListening(Function(String) onResult) async {
    final ready = await _ensureInitialized();
    if (!ready) return false;

    await _speech.listen(
      onResult: (result) => onResult(result.recognizedWords),
      listenOptions: SpeechListenOptions(
        listenMode: ListenMode.dictation,
        cancelOnError: true,
        partialResults: true,
      ),
    );
    return true;
  }

  Future<void> stopListening() async {
    await _speech.stop();
  }

  void dispose() {
    _speech.cancel();
  }
}
