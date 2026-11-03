#!/bin/sh
# tests/functional.sh: the code paths that use the updated packages, exercised
# the way Hermes uses them. Runs INSIDE the image (tests/run.sh mounts it at
# /t), in a throwaway dir. Network: httpbin.org, example.com, wikipedia.org,
# registry.npmjs.org (retried; CI runners have egress).
#
#   pypdf      Hermes' PDF skill scripts: merge, split/rotate, watermark,
#              metadata, AES-256 encrypt/decrypt, AcroForm fill
#   brotli     brotli-encoded responses through httpx and urllib3
#   pyasn1     google-auth: PKCS#8 key decoding, RSA sign/verify
#   tornado    HTTP server + client (python-telegram-bot's webhook stack)
#   chromium   the binary Hermes resolves, rendering real sites
#   npm/undici registry query, npx running a package; docker CLI
set -u
PY=/opt/hermes/.venv/bin/python
SK=/opt/hermes/skills/productivity/pdf/scripts
W=$(mktemp -d); cd "$W" || exit 1
fails=0

cat > "$W/pdftext" <<'EOF'
#!/bin/sh
# pdftext FILE [PASSWORD]: every page's text, then the metadata (pypdf only;
# the skill's pdf_read.py needs pdfplumber, which the image does not ship)
exec /opt/hermes/.venv/bin/python -c "
import pypdf, sys
r = pypdf.PdfReader(sys.argv[1])
if r.is_encrypted:
    r.decrypt(sys.argv[2])
print('\n'.join(p.extract_text() for p in r.pages)); print(r.metadata)" "$@"
EOF
chmod +x "$W/pdftext"; PATH=$W:$PATH; export PATH

check() {   # check NAME CMD...
  name=$1; shift
  if out=$("$@" 2>&1); then echo "  ok   $name"
  else echo "  FAIL $name"; echo "$out" | tail -5 | sed 's/^/       /'; fails=$((fails + 1)); fi
}
retry() {   # retry CMD...: network checks get three tries
  for i in 1 2 3; do "$@" && return 0; sleep $((i * 5)); done; return 1
}

echo "-- pypdf $($PY -c 'import pypdf; print(pypdf.__version__)' 2>/dev/null || echo absent): the PDF skill"
if ! $PY -c 'import pypdf' 2>/dev/null; then
  echo "  skip this Hermes release does not ship pypdf (nothing patched to test)"
elif [ -d "$SK" ]; then
  $PY - <<'PY'
from reportlab.pdfgen import canvas
for name, text in [("a.pdf", "Agent page A"), ("b.pdf", "Agent page B"), ("stamp.pdf", "CONFIDENTIAL")]:
    c = canvas.Canvas(name); c.drawString(100, 700, text); c.showPage(); c.save()
c = canvas.Canvas("form.pdf"); c.drawString(50, 750, "Name:")
c.acroForm.textfield(name="name", x=100, y=740, width=200, height=20); c.save()
PY
  check "merge"                   $PY $SK/pdf_merge.py -o merged.pdf a.pdf b.pdf --bookmarks
  check "merged text"             sh -c "pdftext merged.pdf | grep -q 'page A' && pdftext merged.pdf | grep -q 'page B'"
  check "split + rotate"          $PY $SK/pdf_split.py --pages 2 --rotate 90 -o p2.pdf merged.pdf
  check "split kept only page 2"  sh -c "pdftext p2.pdf | grep -q 'page B' && ! pdftext p2.pdf | grep -q 'page A'"
  check "watermark"               $PY $SK/pdf_watermark.py --stamp stamp.pdf -o wm.pdf merged.pdf
  check "stamp on the pages"      sh -c "pdftext wm.pdf | grep -q CONFIDENTIAL"
  check "metadata set"            $PY $SK/pdf_meta.py --set-meta --title "Patched test" -o meta.pdf merged.pdf
  check "metadata read"           sh -c "pdftext meta.pdf | grep -q 'Patched test'"
  check "encrypt (AES-256)"       $PY $SK/pdf_secure.py --encrypt --user-password s3cret -o enc.pdf merged.pdf
  check "wrong password refused"  sh -c "! pdftext enc.pdf nope >/dev/null 2>&1 && pdftext enc.pdf s3cret | grep -q 'page A'"
  check "decrypt"                 $PY $SK/pdf_secure.py --decrypt --password s3cret -o dec.pdf enc.pdf
  check "decrypted, readable"     $PY -c "
import pypdf
e, d = pypdf.PdfReader('enc.pdf'), pypdf.PdfReader('dec.pdf')
assert e.is_encrypted and not d.is_encrypted
assert 'page A' in d.pages[0].extract_text()"
  echo '{"name": "Agent Li"}' > fields.json
  check "fill form"               $PY $SK/pdf_fill_form.py --fields-json fields.json -o filled.pdf form.pdf
  check "form value stored"       $PY -c "
import pypdf
assert pypdf.PdfReader('filled.pdf').get_fields()['name'].get('/V') == 'Agent Li'"
else
  echo "  skip PDF skill not in this image ($SK)"
fi

echo "-- brotli: compressed HTTP responses"
check "httpx decodes br" retry $PY -c "
import httpx
r = httpx.get('https://httpbin.org/brotli', timeout=30)
assert r.headers.get('content-encoding') == 'br', r.headers
assert r.json()['brotli'] is True"
check "urllib3 decodes br" retry $PY -c "
import urllib3, json
r = urllib3.PoolManager().request('GET', 'https://httpbin.org/brotli', headers={'Accept-Encoding': 'br'}, timeout=30)
assert r.headers.get('content-encoding') == 'br'
assert json.loads(r.data)['brotli'] is True"
check "4 MB round trip" $PY -c "
import brotlicffi, os
d = os.urandom(1 << 16) * 64
assert brotlicffi.decompress(brotlicffi.compress(d)) == d"

echo "-- pyasn1: google-auth"
check "PKCS#8 decode, RSA sign + verify" $PY -c "
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization as s
import google.auth.crypt
from pyasn1.codec.der import decoder
from pyasn1_modules import rfc5208
k = rsa.generate_private_key(public_exponent=65537, key_size=2048)
der = k.private_bytes(s.Encoding.DER, s.PrivateFormat.PKCS8, s.NoEncryption())
pem = k.private_bytes(s.Encoding.PEM, s.PrivateFormat.PKCS8, s.NoEncryption())
info, rest = decoder.decode(der, asn1Spec=rfc5208.PrivateKeyInfo()); assert not rest
sig = google.auth.crypt.RSASigner.from_string(pem).sign(b'hermes')
pub = k.public_key().public_bytes(s.Encoding.PEM, s.PublicFormat.SubjectPublicKeyInfo)
assert google.auth.crypt.RSAVerifier.from_string(pub).verify(b'hermes', sig)"

echo "-- tornado: server + client"
check "serves and fetches" $PY -c "
import asyncio, tornado.web, tornado.httpclient
class H(tornado.web.RequestHandler):
    def post(self): self.write({'echo': self.request.body.decode()})
async def main():
    srv = tornado.web.Application([(r'/hook', H)]).listen(0, '127.0.0.1')
    port = list(srv._sockets.values())[0].getsockname()[1]
    r = await tornado.httpclient.AsyncHTTPClient().fetch(f'http://127.0.0.1:{port}/hook', method='POST', body='ping')
    assert b'\"echo\": \"ping\"' in r.body, r.body
    srv.stop()
asyncio.run(main())"
check "telegram library imports" $PY -c "import telegram, telegram.ext"

echo "-- chromium: what Hermes runs"
check "Hermes resolves Debian's Chromium" sh -c "cd /opt/hermes && p=\$($PY -c 'from hermes_cli.browser_runtime import chromium_executable as c; print(c())') && readlink -f \"\$p\" | grep -qE '^/usr/(bin/chromium|lib/chromium/)'"
check "renders example.com" retry sh -c "timeout 60 chromium --headless --no-sandbox --disable-gpu --dump-dom https://example.com 2>/dev/null | grep -q 'Example Domain'"
check "renders en.wikipedia.org (br)" retry sh -c "timeout 60 chromium --headless --no-sandbox --disable-gpu --dump-dom https://en.wikipedia.org/wiki/Brotli 2>/dev/null | grep -qi compression"

echo "-- node toolchain + docker CLI"
check "npm registry query" retry npm view left-pad version --cache "$W/npmc"
check "npx runs a package" retry sh -c "npx -y --cache $W/npmc cowsay@1.6.0 moo | grep -q moo"
check "docker CLI" docker --version

cd / && rm -rf "$W"
[ "$fails" -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: $fails FAILED"
[ "$fails" -eq 0 ]
