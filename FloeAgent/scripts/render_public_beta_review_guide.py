#!/usr/bin/env python3
"""Render the bilingual review draft from review-walkthrough.json.

Run from the repository root with reportlab and pypdf installed. Visual review
of every rendered page is still required before distributing the PDF.
"""
from pathlib import Path
import json,shutil,html
from reportlab.platypus import SimpleDocTemplate,Paragraph,Spacer,PageBreak,Image,Table,TableStyle,KeepTogether,Flowable
from reportlab.lib.styles import getSampleStyleSheet,ParagraphStyle
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.lib import colors
from reportlab.lib.utils import ImageReader
from pypdf import PdfReader
pdfmetrics.registerFont(TTFont('CJK','/System/Library/Fonts/STHeiti Light.ttc',subfontIndex=0))

data=json.loads(Path('docs/public-beta/review-walkthrough.json').read_text())
sections=data['sections']
Path('output/pdf').mkdir(parents=True,exist_ok=True)
styles=getSampleStyleSheet()
styles.add(ParagraphStyle(name='FloeBody',fontName='CJK',fontSize=10.2,leading=15,spaceAfter=3,wordWrap='CJK',textColor=colors.HexColor('#263B4A')))
styles.add(ParagraphStyle(name='FloeCN',parent=styles['FloeBody'],textColor=colors.HexColor('#526976'),spaceAfter=12))
styles.add(ParagraphStyle(name='FloeTitle',fontName='CJK',fontSize=21,leading=28,spaceAfter=5,textColor=colors.HexColor('#163F51')))
styles.add(ParagraphStyle(name='FloeSubtitle',fontName='CJK',fontSize=12,leading=18,spaceAfter=20,textColor=colors.HexColor('#4E8C98')))
styles.add(ParagraphStyle(name='FloeCaption',fontName='CJK',fontSize=8.5,leading=12,spaceAfter=10,textColor=colors.HexColor('#677D88')))
class OriginalScreenshot(Flowable):
 def __init__(self,path):
  super().__init__();self.path=str(path);w,h=ImageReader(self.path).getSize();self.width=460;self.height=self.width*w/h;self.hAlign='CENTER'
 def draw(self):
  self.canv.saveState();self.canv.rotate(90)
  self.canv.drawImage(self.path,0,-self.width,width=self.height,height=self.width)
  self.canv.restoreState()
story=[]
for i,s in enumerate(sections):
 if i:story.append(PageBreak())
 story+=[Paragraph(html.escape(s['title']),styles['FloeTitle']),Paragraph(html.escape(s['englishTitle']),styles['FloeSubtitle'])]
 if s['image']:
  p=Path(s['image']) if s['image'].startswith('docs/') else Path('docs/evidence/floe-1.7/release-172/screenshots')/s['image']
  story +=[OriginalScreenshot(p),Spacer(1,8),Paragraph(html.escape(s.get('imageCaption', 'Original SDK 27 capture / 原始截图，仅旋转排版 · delivered baseline 172')),styles['FloeCaption'])]
 for n,item in enumerate(s['items'],1):
  story +=[KeepTogether([Paragraph(f'{n}. '+html.escape(item['english']),styles['FloeBody']),Paragraph(html.escape(item['chinese']),styles['FloeCN'])])]
story += [Spacer(1,12),Paragraph('<link href="https://developer.apple.com/app-store/review/guidelines/" color="#347584">Apple App Review Guidelines</link> · <link href="https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information" color="#347584">TestFlight information</link> · <link href="https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.29" color="#347584">Floe Beta 29</link>',styles['FloeCaption'])]
def footer(c,doc):
 c.setStrokeColor(colors.HexColor('#DCE7EB'));c.line(44,43,551,43)
 c.setFont('CJK',8);c.setFillColor(colors.HexColor('#607A86'));c.drawString(44,29,'FLOE · REVIEW PREPARATION / 审核准备稿 · '+data['baseline']+' / '+data['candidate']);c.drawRightString(551,29,str(doc.page))
out=Path('output/pdf/floe-public-beta-review-guide.pdf')
doc=SimpleDocTemplate(str(out),pagesize=(595,842),rightMargin=44,leftMargin=44,topMargin=45,bottomMargin=59,title='Floe Agent - Public Beta Review Walkthrough',author='Floe Agent')
doc.build(story,onFirstPage=footer,onLaterPages=footer)

r=PdfReader(out)
text='\n'.join(p.extract_text() for p in r.pages)
for token in [data['candidate'].split('(')[-1].rstrip(')'),'Whisper','lantern garden 472','星河手记验证','BYOK']:
 assert token in text,token
Path('docs/public-beta/review-walkthrough.md').write_text('# Complete review walkthrough / 完整审核演示说明\n\nBaseline: '+data['baseline']+'. Candidate: '+data['candidate']+'. '+data['status']+'.\n\n'+'\n\n'.join('## '+s['title']+' / '+s['englishTitle']+'\n\n'+'\n\n'.join(x['english']+'\n\n'+x['chinese'] for x in s['items']) for s in sections)+'\n')
shutil.copy2(out,'docs/public-beta/floe-public-beta-review-guide.pdf')
print({'pages':len(r.pages),'bytes':out.stat().st_size,'sections':len(sections),'textChecks':'passed','visualReview':'required'})
