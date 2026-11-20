import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:my_flutter_app/functions_client.dart';

void main() {
  const uploadBase = String.fromEnvironment('UPLOAD_FUNCTIONS_BASE_URL');
  test('hosted upload endpoint is isolated from other Firebase callables', () {
    final client = FirebaseFunctionsClient(
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    );
    if (uploadBase.isNotEmpty) {
      final endpoints = client.candidateEndpointUris('issueReportUploadUrl');
      expect(endpoints, [
        Uri.parse(
          '${uploadBase.replaceFirst(RegExp(r'/+$'), '')}/issueReportUploadUrl',
        ),
      ]);
      expect(endpoints.single.scheme, 'https');
      expect(
        client.candidateEndpointUris('getVerificationStatus').single.host,
        endsWith('.cloudfunctions.net'),
      );
    } else {
      expect(
        client.candidateEndpointUris('issueReportUploadUrl').single.host,
        endsWith('.cloudfunctions.net'),
      );
    }
  });
}
