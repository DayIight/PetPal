import json
from pathlib import Path
root=Path('/Users/benyanzhou/Documents/Codex/app/PetPal/M6_Design/AppIcon/PetPal-Companion')
orange='#E9AC7D'; cream='#FFF4E6'; light='#F5D2AF'
bg='<g id="background-layer"><rect width="1024" height="1024" fill="#E9AC7D"/></g>'
animal='''<g id="animals-layer" stroke-linecap="round" stroke-linejoin="round">
  <g id="cat">
    <path fill="#FFF4E6" d="M499 489 L510 350 Q511 330 529 343 L615 409 Q662 399 713 416 L786 351 Q804 336 806 359 L819 496 Q852 537 846 601 C837 699 774 749 674 746 C581 744 514 686 502 613 Q486 550 499 489Z"/>
    <path fill="#E9AC7D" d="M532 389 L580 426 L530 449Z M779 395 L778 452 L738 430Z"/>
    <path d="M607 545 Q628 522 649 545 M722 545 Q743 522 764 545" fill="none" stroke="#E9AC7D" stroke-width="22"/>
    <path fill="#E9AC7D" d="M663 583 Q684 573 705 583 Q711 589 701 598 L684 611 L667 598 Q656 589 663 583Z"/>
    <path d="M684 608 V624 Q669 646 649 632 M684 624 Q699 646 719 632" fill="none" stroke="#E9AC7D" stroke-width="18"/>
    <path d="M771 589 L807 582 M773 621 L808 626" fill="none" stroke="#E9AC7D" stroke-width="18"/>
  </g>
  <g id="dog">
    <path fill="url(#ear-gradient)" stroke="#FFF4E6" stroke-width="18" d="M490 450 C540 426 574 459 588 518 C601 570 597 629 570 653 C544 674 516 646 506 607Z"/>
    <path fill="#FFF4E6" stroke="#E9AC7D" stroke-width="24" d="M238 508 C248 441 307 410 380 415 C478 419 535 486 540 573 L559 661 C569 747 510 810 409 815 C310 820 233 768 223 688 C218 647 221 562 238 508Z"/>
    <path fill="url(#ear-gradient)" stroke="#FFF4E6" stroke-width="18" d="M270 451 C230 427 192 465 181 522 C169 581 171 643 200 665 C227 685 252 658 261 611 L282 493 Q287 465 270 451Z"/>
    <ellipse cx="330" cy="577" rx="24" ry="29" fill="#E9AC7D"/>
    <ellipse cx="449" cy="567" rx="24" ry="29" fill="#E9AC7D"/>
    <circle cx="324" cy="568" r="9" fill="#FFF4E6"/>
    <circle cx="443" cy="558" r="9" fill="#FFF4E6"/>
    <path fill="#E9AC7D" d="M358 646 Q390 634 422 646 C438 653 416 682 392 685 C369 683 343 654 358 646Z"/>
    <path d="M392 684 V704 M350 707 Q392 739 434 707" fill="none" stroke="#E9AC7D" stroke-width="20"/>
  </g>
</g>'''
social='''<g id="social-symbol-layer" transform="translate(0 -56)">
  <path fill="#FFF4E6" d="M413 177 H608 Q653 177 653 222 V285 Q653 330 608 330 H552 L518 364 Q508 374 508 359 V330 H413 Q368 330 368 285 V222 Q368 177 413 177Z"/>
  <path fill="#E9AC7D" d="M511 288 L472 252 C444 226 480 197 511 227 C542 197 578 226 550 252Z"/>
</g>'''
defs='<linearGradient id="ear-gradient" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#F5D2AF"/><stop offset="1" stop-color="#E9AC7D"/></linearGradient>'
layers=[{'name':'background','svg':bg,'composer':{'include':False}}, {'name':'animals','svg':animal,'defs':defs}, {'name':'social-symbol','svg':social}]
spec={'name':'PetPalCompanion','canvas':1024,'radius':229.0688,'target_platforms':['iOS','Android'],'deliverable_type':'source-package','brief':'Original warm orange and cream dog-and-cat companionship icon, natural heads with a heart chat bubble. iOS primary; Android adaptation guidance. User-requested gentle localized ear gradient and readable strokes.','fill':{'solid':'extended-srgb:0.913725,0.674510,0.490196,1'},'layers':layers}
(root/'tmp/work/spec.json').write_text(json.dumps(spec,indent=2),encoding='utf8')
design={'version':'semantic-icon-design/v0.1','route':'direct-authored-package','app_context':{'app_name':'PetPal','category':'pet social app','job_to_be_done':'find companionship and connect with fellow urban pet owners','tone':'warm, calm, approachable, mature'},'style':{'direction':'custom-flat-two-pet-portrait','svg_convertibility':'high','style_notes':'Explicit user direction: flat illustration, only warm orange and cream, gentle local ear gradient.'},'icon_intent':{'metaphor':'dog and cat leaning together beneath a loving conversation','small_size_readability':'60 and 64 px silhouette and species recognition','must_feel_like':['companionship','warm community','trust'],'must_not_feel_like':['baby toy','corporate badge','3D render']},'layering_policy':{'negative_space_strategy':'overlay-fill-layer','cutouts_are_layers':True,'description':'Facial details are opaque colored overlays; rounded clip is preview-only.'},'canvas':{'size':1024,'composition_anchor':'center','safe_area':{'x':[102.4,921.6],'y':[102.4,921.6]},'alignment':'two faces balanced around center'},'background':{'type':'solid','color':orange,'composer_fill_target':spec['fill']},'layers':[{'id':x['name'],'order':i,'role':x['name'],'format_target':'svg','shape_model':'filled rectangle' if i==0 else 'overlapping organic paths','description': 'solid warm orange field' if i==0 else 'natural dog and cat heads, simple facial overlays' if i==1 else 'cream chat bubble with orange heart','fill':[orange,cream,light] if i==1 else [orange,cream],'geometry_constraints':['crisp boundaries','no texture','no shadows','opaque geometry'],'must_preserve':['only two color families','center 80% safe area'],'must_not_add':['text','numbers','props','clothes','3D material']} for i,x in enumerate(layers)],'conversion_constraints':{'target_layer_count':'3','svg_first':True,'allowed_svg_primitives':['path','rect','ellipse','circle','linearGradient'],'forbidden_in_svg_assets':['text','image','filter','shadow','glow','bevel'],'png_fallback_allowed_only_for':[]}}
(root/'tmp/work/semantic-icon-design.json').write_text(json.dumps(design,indent=2),encoding='utf8')
