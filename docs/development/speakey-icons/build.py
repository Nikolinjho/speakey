# -*- coding: utf-8 -*-
from pathlib import Path
import base64
from html import escape

ROOT = Path(__file__).parent
variants = [
    dict(file='01-voice-key.svg', name='Голосовая клавиша', note='Клавиша, речевой пузырь и звуковая волна в одном знаке. Прямо связывает голос с клавиатурой.', color='Коралловый', body='''
<defs>
  <linearGradient id="v1-bg" x1="32" y1="20" x2="224" y2="244" gradientUnits="userSpaceOnUse"><stop stop-color="#FF9872"/><stop offset="1" stop-color="#EA533D"/></linearGradient>
  <linearGradient id="v1-key" x1="72" y1="62" x2="186" y2="195" gradientUnits="userSpaceOnUse"><stop stop-color="#FFFFFF"/><stop offset="1" stop-color="#FFF0E6"/></linearGradient>
</defs>
<rect x="12" y="12" width="232" height="232" rx="52" fill="url(#v1-bg)"/>
<rect x="13" y="13" width="230" height="230" rx="51" fill="none" stroke="#FFFFFF" stroke-opacity=".25" stroke-width="2"/>
<path d="M66 82a24 24 0 0 1 24-24h76a24 24 0 0 1 24 24v68a24 24 0 0 1-24 24h-27l-28 22v-22H90a24 24 0 0 1-24-24Z" fill="#A92D25" opacity=".18" transform="translate(0 6)"/>
<path d="M66 82a24 24 0 0 1 24-24h76a24 24 0 0 1 24 24v68a24 24 0 0 1-24 24h-27l-28 22v-22H90a24 24 0 0 1-24-24Z" fill="url(#v1-key)"/>
<path d="M96 108v20m21-34v48m22-58v68m21-44v20" fill="none" stroke="#E65D45" stroke-width="10" stroke-linecap="round"/>
'''),
    dict(file='02-ribbon-s.svg', name='Речевая S', note='Монограмма Speakey с хвостом реплики. Самый лаконичный знак для Dock и маленьких размеров.', color='Синий', body='''
<defs><linearGradient id="v2-bg" x1="35" y1="20" x2="224" y2="239" gradientUnits="userSpaceOnUse"><stop stop-color="#558CFF"/><stop offset="1" stop-color="#2849D8"/></linearGradient></defs>
<rect x="12" y="12" width="232" height="232" rx="52" fill="url(#v2-bg)"/>
<rect x="13" y="13" width="230" height="230" rx="51" fill="none" stroke="#FFFFFF" stroke-opacity=".2" stroke-width="2"/>
<path d="M174 77H111c-22 0-37 14-37 32s14 31 36 31h37c21 0 35 12 35 29s-15 30-36 30H82" transform="translate(0 -11)" fill="none" stroke="#122D9E" stroke-opacity=".2" stroke-width="27" stroke-linecap="round"/>
<path d="M174 72h-63c-22 0-37 14-37 32s14 31 36 31h37c21 0 35 12 35 29s-15 30-36 30H82" fill="none" stroke="#FFFFFF" stroke-width="24" stroke-linecap="round"/>
<path d="M82 184h38l-38 38Z" fill="#FFFFFF"/>
'''),
    dict(file='03-mic-space.svg', name='Микрофон и пробел', note='Микрофон опирается на клавишу пробела. Тёмный вариант с явным акцентом на диктовке.', color='Графит и коралл', body='''
<defs><linearGradient id="v3-bg" x1="40" y1="12" x2="210" y2="244" gradientUnits="userSpaceOnUse"><stop stop-color="#373B43"/><stop offset="1" stop-color="#191D25"/></linearGradient><linearGradient id="v3-mic" x1="102" y1="54" x2="150" y2="144" gradientUnits="userSpaceOnUse"><stop stop-color="#FFA780"/><stop offset="1" stop-color="#FF755D"/></linearGradient></defs>
<rect x="12" y="12" width="232" height="232" rx="52" fill="url(#v3-bg)"/>
<rect x="13" y="13" width="230" height="230" rx="51" fill="none" stroke="#FFFFFF" stroke-opacity=".12" stroke-width="2"/>
<rect x="104" y="51" width="48" height="83" rx="24" fill="url(#v3-mic)"/>
<path d="M85 111v7a43 43 0 0 0 86 0v-7M128 163v16" fill="none" stroke="#FFF4E8" stroke-width="10" stroke-linecap="round"/>
<rect x="68" y="180" width="120" height="28" rx="10" fill="#FFF4E8"/>
<path d="M96 191v6h64v-6" fill="none" stroke="#31353D" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/>
'''),
    dict(file='04-dialogue-keys.svg', name='Диалог клавиш', note='Две клавиши-реплики: текст, языки и обмен сообщениями. Более дружелюбный и цветной образ.', color='Молочный, коралл и синий', body='''
<defs><linearGradient id="v4-bg" x1="12" y1="12" x2="244" y2="244" gradientUnits="userSpaceOnUse"><stop stop-color="#FFFCF4"/><stop offset="1" stop-color="#EDE7DA"/></linearGradient></defs>
<rect x="12" y="12" width="232" height="232" rx="52" fill="url(#v4-bg)"/>
<rect x="13" y="13" width="230" height="230" rx="51" fill="none" stroke="#FFFFFF" stroke-opacity=".8" stroke-width="2"/>
<path d="M51 73a19 19 0 0 1 19-19h65a19 19 0 0 1 19 19v51a19 19 0 0 1-19 19h-18l-22 19v-19H70a19 19 0 0 1-19-19Z" fill="#F57759"/>
<path d="M76 89h52M76 108h32" stroke="#FFF8EA" stroke-width="9" stroke-linecap="round"/>
<path d="M116 127a19 19 0 0 1 19-19h51a19 19 0 0 1 19 19v52a19 19 0 0 1-19 19h-15v17l-23-17h-13a19 19 0 0 1-19-19Z" fill="#3D65D9" stroke="#F7F2E7" stroke-width="6"/>
<path d="M179 134v21h-33m0 0 10-10m-10 10 10 10" fill="none" stroke="#FFFFFF" stroke-width="8" stroke-linecap="round" stroke-linejoin="round"/>
'''),
    dict(file='05-speech-flow.svg', name='Поток ввода', note='Звуковая волна переходит в Enter. Показывает превращение речи в готовый текст.', color='Тёмно-зелёный и мята', body='''
<defs><linearGradient id="v5-bg" x1="30" y1="12" x2="226" y2="244" gradientUnits="userSpaceOnUse"><stop stop-color="#194E47"/><stop offset="1" stop-color="#092E2D"/></linearGradient><linearGradient id="v5-line" x1="58" y1="99" x2="197" y2="163" gradientUnits="userSpaceOnUse"><stop stop-color="#91F2C7"/><stop offset="1" stop-color="#E8FFF1"/></linearGradient></defs>
<rect x="12" y="12" width="232" height="232" rx="52" fill="url(#v5-bg)"/>
<rect x="13" y="13" width="230" height="230" rx="51" fill="none" stroke="#A8FFD8" stroke-opacity=".15" stroke-width="2"/>
<path d="M54 125h14l12-32 19 70 20-88 18 50h18" fill="none" stroke="url(#v5-line)" stroke-width="11" stroke-linecap="round" stroke-linejoin="round"/>
<path d="M194 94v47a24 24 0 0 1-24 24h-33m0 0 17-17m-17 17 17 17" fill="none" stroke="url(#v5-line)" stroke-width="11" stroke-linecap="round" stroke-linejoin="round"/>
'''),
]

cards=[]
for i, v in enumerate(variants,1):
    svg=f'''<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256" role="img" aria-labelledby="title desc">
<title id="title">Speakey – {escape(v['name'])}</title>
<desc id="desc">{escape(v['note'])}</desc>
{v['body'].strip()}
</svg>\n'''
    (ROOT/v['file']).write_text(svg)
    uri='data:image/svg+xml;base64,'+base64.b64encode(svg.encode()).decode()
    sizes=''.join(f'<span><img src="{uri}" width="{size}" height="{size}" alt=""/><small>{size}</small></span>' for size in [16,32,64])
    cards.append(f'''<article><div class="card-head"><span>0{i}</span><span>{v['color']}</span></div><div class="canvas"><img src="{uri}" width="196" height="196" alt="{escape(v['name'])}"/></div><h2>{v['name']}</h2><p>{v['note']}</p><div class="sizes">{sizes}</div><a href="{uri}" download="speakey-{v['file']}">Скачать SVG <span>↓</span></a></article>''')

page='''<!doctype html>
<html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><link rel="icon" href="data:,"><title>Speakey – 5 вариантов иконки
</title>
<style>
*{box-sizing:border-box}body{margin:0;font:14px -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#f1f0ec;color:#292a28;--card:#fff;--canvas:#efefec;--line:#e5e4df;--muted:#73766f}body.dark{background:#181b1d;color:#f2f1ed;--card:#24282b;--canvas:#1b1f22;--line:#3b4043;--muted:#aaaeaa}main{max-width:1180px;margin:auto;padding:38px 28px 40px}.eyebrow{font-size:11px;text-transform:uppercase;letter-spacing:1.5px;color:var(--muted)}header{display:flex;align-items:center;justify-content:space-between;gap:24px;margin:12px 0 28px}h1{font-size:34px;letter-spacing:-1.1px;margin:0 0 10px;font-weight:650}.lead{margin:0;color:var(--muted);line-height:1.6;max-width:670px}button{background:var(--card);color:inherit;border:1px solid var(--line);border-radius:8px;padding:10px 14px;white-space:nowrap;cursor:pointer;font:inherit}.grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:18px}article{border:1px solid var(--line);border-radius:16px;background:var(--card);padding:19px;display:flex;flex-direction:column;min-width:0}.card-head{display:flex;justify-content:space-between;gap:12px;font-size:11px;color:var(--muted)}.card-head span:first-child{font-variant-numeric:tabular-nums}.canvas{height:240px;display:flex;align-items:center;justify-content:center;background:var(--canvas);border-radius:11px;margin:15px 0 20px}.canvas img{filter:drop-shadow(0 10px 10px #00000018)}h2{font-size:19px;letter-spacing:-.4px;margin:0 0 9px;font-weight:600}article p{font-size:13px;color:var(--muted);line-height:1.65;margin:0;min-height:65px}.sizes{display:flex;align-items:end;gap:25px;height:105px;margin:16px 0}.sizes span{display:flex;flex-direction:column;align-items:center;gap:7px}.sizes small{font-size:10px;color:var(--muted)}a{border-top:1px solid var(--line);padding-top:14px;margin-top:auto;text-decoration:none;color:inherit;font-size:12px;display:flex;justify-content:space-between}a:hover{color:#e37656}a:focus-visible,button:focus-visible{outline:3px solid #e37656;outline-offset:3px}footer{margin-top:26px;color:var(--muted);font-size:12px;line-height:1.7}.recommend{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:25px;display:flex;flex-direction:column;justify-content:center}.recommend .number{font-size:45px;font-weight:600;letter-spacing:-2px;color:#eb7857;margin-bottom:15px}.recommend h2{font-size:22px}.recommend p{line-height:1.8;color:var(--muted);font-size:13px}.recommend strong{color:inherit;font-weight:600}@media(max-width:900px){.grid{grid-template-columns:repeat(2,minmax(0,1fr))}}@media(max-width:580px){main{padding:24px 16px}header{display:block}header button{margin-top:18px}.grid{grid-template-columns:1fr}h1{font-size:29px}.canvas{height:240px}}

</style>
<main><div class="eyebrow">Speakey · поиск иконки · 27 октября 2026
</div><header><div><h1>Пять направлений для Speakey
</h1><p class="lead">Голос, клавиатура и помощь с текстом. Все варианты в векторе, без шрифтов и внешних картинок. Ниже каждого знака – размеры 16, 32 и 64 px.
</p>
</div><button id="theme" type="button" aria-pressed="false">Тёмный фон
</button>
</header><div class="grid">'''+''.join(cards)+'''<section class="recommend"><div class="number">01 / 02
</div><h2>С чего я бы выбирал
</h2><p><strong>Голосовая клавиша
</strong> точнее объясняет название: речь и клавиатура объединены в одном знаке.
</p><p><strong>Речевая S
</strong> проще по форме и лучше подходит для маленькой иконки. Её удобно развить в монохромный знак для строки меню.
</p>
</section>
</div><footer>SVG: viewBox 256 × 256. Скруглённая подложка входит в файл, пространство за ней прозрачное. Это варианты иконки приложения. Для выбранного знака иконку строки меню подготовим отдельно.
</footer>
</main>
<script>document.getElementById('theme').addEventListener('click',function(){const dark=document.body.classList.toggle('dark');this.textContent=dark?'Светлый фон':'Тёмный фон';this.setAttribute('aria-pressed',String(dark))})
</script>

</html>'''
(ROOT/'index.html').write_text(page)
report=Path.home()/'reports/2026-10-27-speakey-icons.html'
report.write_text(page)
print(f'Создано {len(variants)} SVG')
print(ROOT/'index.html')
print(report)
