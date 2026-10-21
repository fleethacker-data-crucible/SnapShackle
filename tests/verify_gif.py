"""Run node tests/gif_test.js first."""
from pathlib import Path
from PIL import Image
p=Path(__file__).with_name('sample.gif')
im=Image.open(p)
assert im.format=='GIF' and im.size==(64,48) and im.n_frames==4
for i in range(im.n_frames):im.seek(i);im.load()
print('PASS: 4 GIF frames decoded independently')