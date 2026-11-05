"""Smart redaction: detection of sensitive text in OCR word boxes."""
import os
from pathlib import Path
from playwright.sync_api import sync_playwright

root = Path(__file__).resolve().parents[1]
executable = os.environ.get('SNAPSHACKLE_CHROMIUM') or os.environ.get('CUTTERMK_CHROMIUM') or None

CASES = r'''()=>{
  // Words laid out left to right, 10px per character plus a 6px gap, on one line per row.
  function line(row,...texts){let x=10;const words=texts.map(t=>{const w={text:t,x,y:20+row*30,w:t.length*10,h:18};x+=w.w+6;return w});return {text:texts.join(' '),words}}
  const lines=[
    line(0,'Contact','j.smith@corp.org','today'),
    line(1,'SSN','123-45-6789'),
    line(2,'Call','(757)','555-0142','now'),
    line(3,'EDIPI','1234567890'),
    line(4,'Card','4111','1111','1111','1111'),
    line(5,'Host','10.0.0.255'),
    line(7,'Key','sk-DEMO0000000000000000AAAA','token','ghp_AAAAAAAAAAAAAAAAAAAAAAAA'),
    // Must NOT match: invalid IP octet, failing Luhn card, a date, an 11-digit number.
    line(6,'bad','999.1.1.1','4111','1111','1111','1112','2026-10-24','12345678901'),
  ];
  const found=SnapShackleRedact.detect(lines,{pad:0});
  const term=SnapShackleRedact.findText([line(0,'Project','STARLING','and','project','starling','Docs')],'project starling',{pad:0});
  const detector=SnapShackleRedact.detect(SnapShackleRedact.fromTextDetector([{rawValue:'mail a@b.co',boundingBox:{x:5,y:6,width:100,height:12}}]),{pad:0});
  return {found:found.map(f=>({kind:f.kind,text:f.text,box:f.box})),term:term.map(t=>t.box),detector:detector.map(d=>d.box)};
}'''

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True, executable_path=executable, args=['--no-sandbox'])
    page = browser.new_page()
    page.set_content('<html><body></body></html>')
    page.add_script_tag(path=str(root / 'assets/redact.js'))
    data = page.evaluate(CASES)
    browser.close()

kinds = {f['kind']: f for f in data['found']}
print(data['found'])
assert sorted(kinds) == ['card', 'dodid', 'email', 'ip', 'phone', 'secret', 'ssn'], sorted(kinds)
assert len(data['found']) == 8, 'false positives: ' + repr([f for f in data['found'] if f['box']['y'] >= 200])
assert kinds['email']['text'] == 'j.smith@corp.org'
# The phone spans two OCR words; its box must cover both.
phone = kinds['phone']['box']
assert phone['x'] == 56 and phone['x2'] == 56 + 50 + 6 + 80, phone
# The card spans four words.
assert kinds['card']['box']['x2'] - kinds['card']['box']['x'] == 4 * 40 + 3 * 6, kinds['card']['box']
# Case-insensitive phrase search finds both instances.
assert len(data['term']) == 2, data['term']
# Browser OCR (line boxes only) still yields a box.
assert data['detector'] == [{'x': 5, 'y': 6, 'x2': 105, 'y2': 18}], data['detector']
print('PASS: email, SSN, phone, DoD ID, card (Luhn), IP found with correct boxes; no false positives; phrase search')
