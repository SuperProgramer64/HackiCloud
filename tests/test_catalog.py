"""Catalog credentials must stay bounded and existing native cache entries unchanged."""
import time
import unittest
from hackicloud.catalog import validate_token, cached_result

class CatalogTests(unittest.TestCase):
 def test_native_token_rejects_unsafe_input_and_expiry(self):
  now=time.time();good={'token':'a'*256,'expiry':now+86400}
  self.assertEqual(validate_token(good,now),good)
  for bad in [dict(good,token='x\r\nAuthorization:y'),dict(good,expiry=True),dict(good,expiry=float('nan')),dict(good,expiry=now-1),dict(good,expiry=now+61*86400),dict(good,token='a'*8193),dict(good,extra='PRIVATE')]:
   with self.assertRaises(ValueError):validate_token(bad,now)
 def test_cache_status_has_only_public_metadata(self):
  self.assertEqual(cached_result('STATUS {"present":true,"valid":true,"expiry":1900000000}\n')['valid'],True)
  for bad in ['STATUS {"token":"PRIVATE"}','STATUS {"present":1,"valid":true,"expiry":1900000000}','STATUS {"present":true,"valid":true,"expiry":NaN}']:
   with self.assertRaises(ValueError):cached_result(bad)
