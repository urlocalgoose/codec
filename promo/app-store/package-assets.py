#!/usr/bin/env python3
"""Validate and package native screenshots without contacting Apple."""
import argparse,hashlib,html,json,shutil,struct,zipfile
from pathlib import Path

REPO=Path(__file__).resolve().parents[2]
SIZES={'iphone-6.9':(1320,2868),'ipad-13':(2064,2752)}
ICON=REPO/'ios/CodecMobile/App/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png'

def listing_copy(listing):
    counts={}
    for key,limit in [('subtitle',30),('promotionalText',170),('description',4000),('keywords',100)]:
        value=listing.get(key)
        if not isinstance(value,str) or not value.strip():
            raise ValueError(f'Missing listing field: {key}')
        count=len(value.encode('utf-8')) if key=='keywords' else len(value)
        unit='UTF-8 bytes' if key=='keywords' else 'characters'
        if count>limit:
            raise ValueError(f'{key} exceeds {limit} {unit} ({count})')
        counts[key]={'count':count,'limit':limit,'unit':unit}
    name=listing.get('existingListingName')
    if name is not None and (not isinstance(name,str) or not name.strip()):
        raise ValueError('existingListingName must be a verified name or null')
    category=listing.get('primaryCategory') or listing.get('suggestedPrimaryCategory')
    values=[
        ('existingListingName','App name' if name else 'App name — keep existing',
         name or 'Keep the existing reserved App Store Connect name. It has not been verified in this handoff; do not rename the app.'),
        ('subtitle','Subtitle',listing['subtitle']),
        ('promotionalText','Promotional text',listing['promotionalText']),
        ('description','Description',listing['description']),
        ('keywords','Keywords',listing['keywords']),
        ('supportURL','Support URL',listing.get('supportURL')),
        ('privacyPolicyURL','Privacy policy URL',listing.get('privacyPolicyURL')),
        ('marketingURL','Marketing URL',listing.get('marketingURL') or listing.get('marketingURLCandidate')),
        ('primaryCategory','Primary category' if listing.get('primaryCategory') else 'Suggested primary category',category),
    ]
    for key,_,value in values:
        if not isinstance(value,str) or not value.strip():
            raise ValueError(f'Missing listing field: {key}')
    return values,counts

def png_info(path):
    data=path.read_bytes()
    assert data[:8]==b'\x89PNG\r\n\x1a\n', f'Not PNG: {path.name}'
    width,height,depth,color=struct.unpack('>IIBB',data[16:26])
    assert depth==8 and color==2, f'Expected opaque 8-bit RGB: {path.name}'
    return width,height

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--posters',required=True,type=Path)
    parser.add_argument('--capture',required=True,type=Path)
    parser.add_argument('--licensed-bundle',required=True,type=Path)
    parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args()
    config=json.loads((REPO/'promo/app-store/screenshots.json').read_text())
    listing=json.loads((REPO/'promo/app-store/listing.en-US.json').read_text())
    fields,copy_validation=listing_copy(listing)
    assert len(config['screens'])==6, 'Expected six screenshots per device family'
    assert png_info(ICON)==(1024,1024), 'Expected the 1024×1024 app icon from the native build'
    for copy,poster in zip(listing['screenshots'],config['screens'],strict=True):
        assert copy['id']==poster['id'] and copy['source']==poster['source']
        assert copy['headlineLines']==poster['headline'] and copy['caption']==poster['caption']
    receipt=json.loads((args.capture/'capture-receipt.json').read_text())
    assert receipt.get('tracks')==100, 'Expected the isolated 100-song licensed collection'
    assert (args.licensed_bundle/'licenses/manifest.json').is_file()
    output=args.output.resolve();output.mkdir(parents=True,exist_ok=True)
    package=output/'Codec-App-Store-Kit'
    package.mkdir(exist_ok=False)
    report={'copyStatus':'Editable draft','submittedToApple':False,'screenshots':[],'videoPreviewsIncluded':False,
            'copyValidation':copy_validation}
    for family,size in SIZES.items():
        target=package/'Screenshots'/family;target.mkdir(parents=True)
        raw=package/'Raw captures'/family;raw.mkdir(parents=True)
        for screen in config['screens']:
            source=args.posters/family/(screen['id']+'.png')
            assert png_info(source)==size
            assert png_info(args.capture/'screenshots'/family/screen['source'])==size
            shutil.copy2(source,target/source.name)
            shutil.copy2(args.capture/'screenshots'/family/screen['source'],raw/screen['source'])
            report['screenshots'].append({'family':family,'file':source.name,'width':size[0],'height':size[1],'opaque':True})
    copy=package/'Copy';copy.mkdir()
    for file in ['listing.en-US.json','screenshots.json']:shutil.copy2(REPO/'promo/app-store'/file,copy/file)
    for key,_,value in fields:(copy/(key+'.txt')).write_text(value+'\n',encoding='utf-8')
    full_copy='Codec — App Store listing copy\nLocale: '+listing.get('locale','en-US')+'\nDraft for local review. Not uploaded or submitted to Apple.\n\n'
    full_copy+='\n\n'.join(label+'\n'+value for _,label,value in fields)+'\n'
    (copy/'App-Store-Copy.txt').write_text(full_copy,encoding='utf-8')
    review_notes=REPO/'promo/app-store/review-notes.template.txt'
    report['reviewNotesTemplateIncluded']=review_notes.is_file()
    if review_notes.is_file():shutil.copy2(review_notes,copy/review_notes.name)
    shutil.copy2(REPO/'docs/app-store-listing.md',copy/'Listing-notes.md')
    icon_dir=package/'Icon';icon_dir.mkdir()
    shutil.copy2(ICON,icon_dir/'Codec-1024.png')
    report['icon']={'file':'Icon/Codec-1024.png','width':1024,'height':1024,
                    'sha256':hashlib.sha256(ICON.read_bytes()).hexdigest(),'source':'Native app asset; original bytes preserved'}
    credits=package/'Credits';credits.mkdir()
    shutil.copy2(args.licensed_bundle/'CREDITS.md',credits/'CREDITS.md')
    shutil.copy2(args.licensed_bundle/'licenses/manifest.json',credits/'license-manifest.json')
    shutil.copy2(args.posters/'contact-sheet.png',package/'Screenshot-overview.png')
    screenshot_order='\n'.join(f'{index}. {screen["id"]}.png — {" ".join(screen["headline"])}' for index,screen in enumerate(config['screens'],1))
    readme='''Codec — App Store local handoff

Six captioned screenshots each for 6.9-inch iPhone and 13-inch iPad.
Raw native captures, pasteable listing copy, the app icon, and source credits are included.
There are no video previews in this package.

All screenshots use the isolated 100-song licensed demonstration collection.
Codec requires a Codec server and music files. No catalog is included.

Screenshot upload order, when uploads are approved:
Use Screenshots/iphone-6.9 for the 6.9-inch iPhone slots and Screenshots/ipad-13
for the 13-inch iPad slots. Upload the following six files in this order for each device:
'''+screenshot_order+'''
Raw captures/ and Screenshot-overview.png are references, not additional upload slots.

Copy/App-Store-Copy.txt contains every public listing field in one place.
Copy/ also contains individual field files and the editable JSON source.
Keep the existing reserved App Store Connect name and SKU.
Icon/Codec-1024.png is the unchanged native app asset. The App Store icon comes
from the submitted build; this file is a reference, not a separate icon upload.
'''
    if review_notes.is_file():
        readme+='Copy/review-notes.template.txt is a token-free template. Complete review access privately in App Store Connect; do not add credentials to this kit.\n'
    readme+='''
Account-specific settings are not verified here: review contact, copyright,
age rating, privacy labels, pricing, availability, selected build, and release settings.
Add the owner's chosen direct support contact to the support page before submission;
it currently provides a GitHub Issues link. See Copy/Listing-notes.md.
This package has not been uploaded or submitted to Apple.
The upload, App Review submission, and release hold remains in force.
'''
    (package/'README.txt').write_text(readme,encoding='utf-8')
    (package/'asset-validation.json').write_text(json.dumps(report,indent=2)+'\n')
    files=sorted(p for p in package.rglob('*') if p.is_file())
    assert not any(p.suffix.lower() in {'.mp4','.mov','.m4v'} for p in files)
    (package/'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.relative_to(package).as_posix()+'\n' for p in files))
    archive=output/'Codec-App-Store-Kit.zip'
    with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as bundle:
        for file in sorted(p for p in package.rglob('*') if p.is_file()):bundle.write(file,file.relative_to(output))
    sections=[]
    for family,title in [('iphone-6.9','iPhone'),('ipad-13','iPad')]:
        pictures=''.join('<figure><a href="Codec-App-Store-Kit/Screenshots/'+family+'/'+screen['id']+'.png"><img loading="lazy" src="Codec-App-Store-Kit/Screenshots/'+family+'/'+screen['id']+'.png" alt="'+html.escape(' '.join(screen['headline']))+'"></a><figcaption>'+html.escape(' '.join(screen['headline']))+'</figcaption></figure>' for screen in config['screens'])
        sections.append('<section id="'+family+'"><h2>'+title+'</h2><div class="screens">'+pictures+'</div></section>')
    review="""<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Codec — App Store handoff</title><style>
:root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;padding:40px max(24px,calc((100vw - 1440px)/2));background:#101312;color:#eef2ed;font:16px/1.6 -apple-system,BlinkMacSystemFont,sans-serif}
h1{font-size:clamp(28px,4vw,44px);line-height:1.15;letter-spacing:-.035em;margin:12px 0 18px}
p{max-width:65ch;color:#b7c3bb}a{color:inherit;outline-offset:6px}.brand{color:#aab8b0;font-size:16px}
nav{display:flex;flex-wrap:wrap;gap:12px;margin-top:24px}nav a{padding:10px 16px;border:1px solid #77807970;border-radius:12px;text-decoration:none}
nav a:first-child{background:#eef2ed;color:#101312}section{margin-top:48px}h2{font-size:24px;letter-spacing:-.025em}
.screens{display:grid;grid-template-columns:repeat(6,minmax(0,1fr));gap:16px}figure{margin:0}figcaption{font-size:14px;margin-top:8px;color:#b7c3bb}
.screens img{width:100%;display:block;border-radius:8px;border:1px solid #fff2}footer{margin:48px 0 20px;color:#aab8b0;font-size:14px}
.listing-copy{max-width:75ch}.listing-copy dt{margin-top:24px;font-weight:600}.listing-copy dd{margin:8px 0 0;white-space:pre-wrap;overflow-wrap:anywhere;color:#b7c3bb}
@media(max-width:900px){.screens{grid-template-columns:repeat(3,minmax(0,1fr))}}
@media(max-width:520px){body{padding:24px 20px}.screens{grid-template-columns:repeat(2,minmax(0,1fr))}section{margin-top:36px}}
</style><div class="brand">Codec</div><main id="screenshots"><h1>App Store screenshots</h1>
<p>Six screenshots for iPhone and iPad. Select an image to view it at full size.</p>
<nav><a href="Codec-App-Store-Kit.zip" download>Download App Store kit</a>
<a href="https://codec.codie.sh/" target="_blank" rel="noopener">Codec website</a>
<a href="Codec-App-Store-Kit/Copy/App-Store-Copy.txt">Full listing copy</a>
<a href="Codec-App-Store-Kit/Icon/Codec-1024.png">App icon</a></nav>"""
    listing_html=''.join('<dt>'+html.escape(label)+'</dt><dd>'+html.escape(value)+'</dd>' for _,label,value in fields)
    review+=''.join(sections)+'<section id="listing-copy"><h2>Listing copy</h2><dl class="listing-copy">'+listing_html+'</dl></section></main><footer>Draft · Not submitted to Apple · Source credits included</footer></html>'
    (output/'index.html').write_text(review)
    print(json.dumps({'archive':str(archive),'bytes':archive.stat().st_size,'screenshots':len(report['screenshots']),'videoPreviewsIncluded':False},indent=2))

if __name__=='__main__':main()
