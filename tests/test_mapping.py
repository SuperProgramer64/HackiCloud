"""Device injection must preserve unrelated mappings and reject conflicting hooks."""
from pathlib import Path
import subprocess,tempfile,unittest
SRC=Path(__file__).resolve().parents[1]/'native/device'
CODE=r'''#include "mapping.h"
#include <assert.h>
#include <string.h>
int main(void){char out[8192];
assert(hcloud_mapping("/lib/other.dylib SpringBoard",out,sizeof(out),1)==0);
assert(strstr(out,"/lib/other.dylib SpringBoard")&&strstr(out,"hackicloud_anonymous akd")&&strstr(out,"hackicloud_signer Preferences"));
char again[8192];assert(hcloud_mapping(out,again,sizeof(again),1)==0);assert(!strcmp(out,again));
assert(hcloud_mapping(out,again,sizeof(again),0)==0);assert(!strcmp(again,"/lib/other.dylib SpringBoard"));
assert(hcloud_mapping("/lib/foreign.dylib akd",out,sizeof(out),1)==2);
assert(hcloud_mapping("/lib/foreign.dylib Preferences",out,sizeof(out),1)==2);
assert(hcloud_mapping("/lib/other.dylib SpringBoard",out,8,1)!=0);
return 0;}'''
class Mapping(unittest.TestCase):
 def test_ownership_conflict_idempotence_and_capacity(self):
  with tempfile.TemporaryDirectory()as d:
   p=Path(d);(p/'check.c').write_text(CODE)
   r=subprocess.run(['clang','-fsanitize=address,undefined','-I',str(SRC),str(p/'check.c'),'-o',str(p/'check')],capture_output=True,text=True);self.assertEqual(r.returncode,0,r.stderr)
   r=subprocess.run([str(p/'check')],capture_output=True,text=True);self.assertEqual(r.returncode,0,r.stderr)
