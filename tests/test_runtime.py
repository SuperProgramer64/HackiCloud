import base64
import unittest
from hackicloud.runtime import validate_request

class RuntimeValidation(unittest.TestCase):
 def test_replay_wrong_operation_and_missing_consent_fail(self):
  nonce='a'*32;body=b'fixture-only'
  row={'op':'nac-sign','nonce':nonce,'request':2,'body':base64.b64encode(body).decode()}
  self.assertEqual(validate_request(row,nonce,'signer',1), (2,body))
  for bad in [dict(row,request=1),dict(row,request=True),dict(row,nonce='b'*32),dict(row,op='anything'),dict(row,body='!invalid')]:
   with self.assertRaises(ValueError):validate_request(bad,nonce,'signer',1)
  with self.assertRaises(ValueError):validate_request(dict(row,extra='PRIVATE'),nonce,'signer',1)
 def test_anonymous_requests_have_no_signing_payload(self):
  n='a'*32;row={'op':'anisette','nonce':n,'request':1}
  self.assertEqual(validate_request(row,n,'anonymous',0),(1,None))
  with self.assertRaises(ValueError):validate_request(dict(row,body='PRIVATE'),n,'anonymous',0)
