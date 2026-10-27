import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

void registerHongguoLicenses() {
  LicenseRegistry.addLicense(() async* {
    final license = await rootBundle.loadString(
      'native/licenses/hongguo-GPL-3.0.txt',
    );
    yield LicenseEntryWithLineBreaks(
      ['Hongguo native signing'],
      '''GPL-3.0-only

Signing and Spade algorithms adapted from woshishiq1/drpys
commit 22261adfa31435e3b3ef5a730b8a2a75bcaf1715, spider/js/红果果[短].js,
via N3urda/hongguoTV eea73e6a45569a2cbbb9440f7cd5290c459b0b70.

JavaScript reference: jackotom/hongguo-drama
74a8c7523790df69fbde721ea4dc8194b6412475, src/native/app-source.js.
Go port reference: limbia/guoapp
96d3a6407ade99be5b8fd2ce18206c66bda2d69a.

Local changes: request preparation, F13 rolling state, identity generation,
bounded transport, source fallback, media variants and diagnostics.

$license''',
    );
  });
}
