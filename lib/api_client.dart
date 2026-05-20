import 'dart:convert';
import 'dart:io';

import 'package:card_detacstion_app/api_config.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

/// Uploads a JPEG and parses card-detection JSON (or a clear error).
class CardDetectionApiClient {
  const CardDetectionApiClient();

  Future<({Map<String, dynamic> body, int elapsedMs, int statusCode})>
      detectCard(File imageFile) async {
    final sw = Stopwatch()..start();
    final uri = Uri.parse(kDetectCardEndpoint);

    final req = http.MultipartRequest('POST', uri);
    if (kHfApiToken.isNotEmpty) {
      req.headers['Authorization'] = 'Bearer $kHfApiToken';
    }
    req.files.add(
      await http.MultipartFile.fromPath(
        'file',
        imageFile.path,
        contentType: MediaType('image', 'jpeg'),
      ),
    );

    final res = await http.Response.fromStream(await req.send());
    sw.stop();

    return (
      body: _parseResponseBody(
        statusCode: res.statusCode,
        rawBody: res.body,
        requestUrl: uri.toString(),
      ),
      elapsedMs: sw.elapsedMilliseconds,
      statusCode: res.statusCode,
    );
  }

  static Map<String, dynamic> _parseResponseBody({
    required int statusCode,
    required String rawBody,
    required String requestUrl,
  }) {
    final trimmed = rawBody.trimLeft();
    final looksLikeHtml = trimmed.startsWith('<!DOCTYPE') ||
        trimmed.startsWith('<html') ||
        trimmed.contains('<h1>404</h1>');

    if (looksLikeHtml) {
      return {
        'success': false,
        'message':
            'API endpoint not found (404). The Hugging Face Space may be '
            'stopped or the URL is wrong.\n'
            'URL: $requestUrl\n'
            'Update HF_DETECT_CARD_ENDPOINT in env.json to match your Space.',
      };
    }

    if (statusCode == 200) {
      try {
        final decoded = json.decode(rawBody);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {}
      return {'success': false, 'message': 'Invalid JSON from API'};
    }

    if (statusCode == 401 || statusCode == 403) {
      return {
        'success': false,
        'message':
            'API auth failed ($statusCode). Check HF_API_TOKEN in env.json.',
      };
    }

    if (statusCode == 404) {
      return {
        'success': false,
        'message':
            'API not found (404). Verify HF_DETECT_CARD_ENDPOINT in env.json.',
      };
    }

    try {
      final decoded = json.decode(rawBody);
      if (decoded is Map && decoded['message'] != null) {
        return {
          'success': false,
          'message': decoded['message'].toString(),
        };
      }
    } catch (_) {}

    return {'success': false, 'message': 'Server error $statusCode'};
  }
}
