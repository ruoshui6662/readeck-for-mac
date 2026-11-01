import Foundation

/// Presentation-only classification. Never replaces nodes or edits text: server
/// annotation paths continue to address exactly the saved article fragment.
enum ReaderReflow {
    static let bootstrap = #"""
    (() => {
        const root=document.getElementById('reader-content');
        if(!root || window.__readerReflow) return;
        const protectedContent='pre,code,kbd,samp,svg,math,ruby,textarea';
        const blocks='p,div,section,article,figure,blockquote,ul,ol,li,h1,h2,h3,h4,h5,h6';
        const fields=['data-reader-block','data-reader-hidden','data-reader-whitespace','data-reader-media'];
        const records=Array.from(root.querySelectorAll('*')).map(node=>({node,
            style:node.getAttribute('style'), attributes:fields.map(key=>node.getAttribute(key)),
            hidden:false, whitespace:null}));
        const sheets=Array.from(document.styleSheets).filter(sheet=>
            !['reader-style','reader-annotation-style'].includes(sheet.ownerNode?.id))
            .map(sheet=>({sheet,disabled:sheet.disabled}));
        // Read author visibility before disabling author styles. Hidden navigation,
        // captions and paywall alternatives must never be revealed by a reset.
        for(const entry of records) {
            const style=getComputedStyle(entry.node);
            entry.hidden=entry.node.hidden ||
                style.display==='none' || style.visibility==='hidden' || style.visibility==='collapse' || style.contentVisibility==='hidden';
            if(entry.node.matches('img,video')) { const r=entry.node.getBoundingClientRect();entry.mediaWidth=r.width;entry.mediaHeight=r.height; }
            if(['pre','pre-wrap','pre-line','break-spaces'].includes(style.whiteSpace)) entry.whitespace=style.whiteSpace;
        }
        const resetProperties=['font','font-family','font-size','line-height','letter-spacing','word-spacing',
            'color','background','background-color','background-image','text-align','text-indent',
            'margin','margin-top','margin-bottom','margin-left','margin-right','margin-block','margin-inline',
            'padding','padding-top','padding-bottom','padding-left','padding-right','padding-block','padding-inline',
            'width','min-width','max-width','height','min-height','max-height','inline-size','block-size',
            'max-inline-size','min-inline-size','max-block-size','min-block-size',
            'position','top','bottom','left','right','inset','float','clear','transform','zoom',
            'display','overflow','overflow-x','overflow-y','border','border-width','border-style','border-color',
            'box-shadow','border-radius','text-shadow','white-space'];
        function restoreAttributes(entry) {
            if(entry.style===null) entry.node.removeAttribute('style'); else entry.node.setAttribute('style',entry.style);
            fields.forEach((key,index)=>{ const value=entry.attributes[index];
                if(value===null) entry.node.removeAttribute(key); else entry.node.setAttribute(key,value); });
        }
        function setEnabled(enabled) {
            root.dataset.readerLayout=enabled?'unified':'compatible';
            for(const entry of records) restoreAttributes(entry);
            for(const entry of sheets) entry.sheet.disabled=enabled?true:entry.disabled;
            if(!enabled) return;
            for(const entry of records) {
                const node=entry.node;
                if(entry.hidden) node.dataset.readerHidden='true';
                if(entry.whitespace) node.dataset.readerWhitespace=entry.whitespace;
                if(node.closest(protectedContent)) continue;
                for(const key of resetProperties) node.style.removeProperty(key);
                if(!node.getAttribute('style')?.trim()) node.removeAttribute('style');
                if(node.matches(blocks)) node.dataset.readerBlock='container';
            }
            for(const entry of records) {
                const node=entry.node;
                if(!node.matches(blocks) || node.closest(protectedContent) || node.closest('[data-reader-hidden="true"]')) continue;
                if(!node.textContent.trim() && !node.querySelector('img,video,audio,svg,math,table,hr,iframe,object,embed') &&
                   !node.closest('[data-reader-whitespace]')) {
                    node.dataset.readerBlock='spacer';
                }
            }
            // Choose the innermost media block so nested publisher sections do
            // not each contribute another image margin. No figure wrappers added.
            for(const entry of [...records].reverse()) {
                const node=entry.node;
                if(!node.matches('p,div,section,figure') || node.closest(protectedContent) || node.closest('[data-reader-hidden="true"]')) continue;
                const media=node.querySelector('img,video');
                if(!media) continue;
                if(node.matches('figure')) node.dataset.readerBlock='figure';
                else if(!node.textContent.trim() && !node.querySelector('[data-reader-block="image"],[data-reader-block="figure"]')) node.dataset.readerBlock='image';
            }
            for(const entry of records) {
                const node=entry.node;
                if(node.matches('p') && node.dataset.readerBlock==='container') node.dataset.readerBlock='paragraph';
                if(!node.matches('img,video') || node.closest(protectedContent) || node.closest('[data-reader-hidden="true"]')) continue;
                if(node.closest('[data-reader-block="image"],[data-reader-block="figure"]')) continue;
                const textOwner=node.parentElement.closest('p,li,td,th,figcaption');
                const small=entry.mediaWidth>0 && entry.mediaWidth<=48 && entry.mediaHeight>0 && entry.mediaHeight<=48;
                node.dataset.readerMedia=textOwner?.textContent.trim() && small?'inline':'block';
            }
        }
        let position=null, captureTimer=null, layoutTimer=null, userScrollingUntil=0, gestureVersion=0, pendingStyle=null;
        function rangeRect(range) {
            const rects=Array.from(range.getClientRects());
            return rects.find(r=>r.width>0&&r.height>0) || range.getBoundingClientRect();
        }
        function capturePosition() {
            const box=root.getBoundingClientRect(), style=getComputedStyle(root);
            const x=Math.max(1,Math.min(innerWidth-2,box.left+parseFloat(style.paddingLeft)+6));
            let range=null;
            for(const y of [40,72,104,136]) {
                const caret=document.caretRangeFromPoint?.(x,Math.min(innerHeight-2,y));
                if(caret && caret.startContainer.nodeType===Node.TEXT_NODE && root.contains(caret.startContainer) && caret.startContainer.length) {
                    range=caret.cloneRange();
                    const offset=Math.min(range.startOffset,range.startContainer.length-1);
                    range.setStart(range.startContainer,offset);range.setEnd(range.startContainer,offset+1);
                    if(rangeRect(range).height>0) break;
                    range=null;
                }
            }
            if(!range) { position=null;return null; }
            position={range,top:rangeRect(range).top};
            return position;
        }
        function restorePosition(saved=position) {
            if(!saved || !root.contains(saved.range.startContainer)) return;
            const delta=rangeRect(saved.range).top-saved.top;
            if(Number.isFinite(delta) && Math.abs(delta)>.5) {
                const adjusting=window.__readerAdjusting;
                window.__readerAdjusting=true;
                scrollBy(0,delta);
                if(!adjusting) setTimeout(()=>{window.__readerAdjusting=false;},80);
            }
            position=saved;
        }
        function beginStyleChange() {
            if(!pendingStyle || pendingStyle.gesture!==gestureVersion)
                pendingStyle={position:capturePosition(),gesture:gestureVersion};
            return pendingStyle;
        }
        function finishStyleChange(change) {
            if(change.gesture===gestureVersion) restorePosition(change.position);
            else capturePosition();
            if(change===pendingStyle) pendingStyle=null;
        }
        function scheduleCapture() {
            clearTimeout(captureTimer);captureTimer=setTimeout(capturePosition,50);
        }
        function userGesture() {
            gestureVersion++;userScrollingUntil=performance.now()+180;
            position=null;scheduleCapture();
        }
        window.addEventListener('wheel',userGesture,{passive:true});
        window.addEventListener('pointerdown',userGesture,{passive:true});
        window.addEventListener('keydown',event=>{
            if(['ArrowUp','ArrowDown','PageUp','PageDown','Home','End',' '].includes(event.key)) userGesture();
        });
        window.addEventListener('scroll',()=>{
            if(!window.__readerAdjusting || performance.now()<userScrollingUntil) scheduleCapture();
        },{passive:true});
        function layoutChanged() {
            clearTimeout(layoutTimer);
            layoutTimer=setTimeout(()=>{
                if(window.__readerAdjusting) { layoutTimer=setTimeout(layoutChanged,30);return; }
                if(performance.now()<userScrollingUntil) {capturePosition();return;}
                restorePosition();
            },20);
        }
        root.addEventListener('load',layoutChanged,true);
        const observer=new ResizeObserver(layoutChanged);observer.observe(root);
        document.fonts?.ready.then(layoutChanged);
        window.__readerReflow={setEnabled,capturePosition,restorePosition,beginStyleChange,finishStyleChange};
        setEnabled(document.body.dataset.readerUnified!=='false');
        capturePosition();
    })();
    """#

    static let css = """
    #reader-content[data-reader-layout="unified"] {
      text-align: var(--reader-alignment); }
    #reader-content[data-reader-layout="unified"] :where(p,div,section,article,figure,blockquote,ul,ol,li,h1,h2,h3,h4,h5,h6) {
      position: static !important; float: none !important; clear: none !important; transform: none !important;
      inset: auto !important; inline-size: auto !important; block-size: auto !important;
      max-block-size: none !important; min-block-size: 0 !important;
      background: transparent !important; box-shadow: none !important; text-shadow: none !important;
      color: inherit !important; padding: 0 !important; border: 0 !important;
      text-indent: 0 !important; text-align: inherit !important; }
    #reader-content[data-reader-layout="unified"] :where(div,section,article) { display: block !important; margin: 0 !important; }
    #reader-content[data-reader-layout="unified"] :where(span,a,font,small) {
      font-family: inherit !important; font-size: inherit !important; line-height: inherit !important;
      color: inherit !important; background: transparent !important; letter-spacing: inherit !important; }
    #reader-content[data-reader-layout="unified"] p {
      display: block !important; margin: 0 0 var(--reader-paragraph) !important;
      text-indent: var(--reader-indent) !important; }
    #reader-content[data-reader-layout="unified"] :where(li,blockquote,figcaption) p { text-indent: 0 !important; }
    #reader-content[data-reader-layout="unified"] :where(h1,h2,h3,h4,h5,h6) { margin: 1.6em 0 .65em !important; }
    #reader-content[data-reader-layout="unified"] [data-reader-hidden="true"][data-reader-hidden] { display: none !important; }
    #reader-content[data-reader-layout="unified"] [data-reader-block="spacer"] {
      display: block !important; height: 0 !important; block-size: 0 !important;
      min-height: 0 !important; margin: 0 !important; padding: 0 !important; line-height: 0 !important; }
    #reader-content[data-reader-layout="unified"] [data-reader-block="spacer"] br { display: none !important; }
    #reader-content[data-reader-layout="unified"] :is([data-reader-block="image"],[data-reader-block="figure"]) {
      display: block !important; margin: var(--reader-image-gap) 0 !important; text-indent: 0 !important; text-align: center !important; }
    #reader-content[data-reader-layout="unified"] [data-reader-block="figure"] [data-reader-block="image"] { margin: 0 !important; }
    #reader-content[data-reader-layout="unified"] :is([data-reader-block="image"],[data-reader-block="figure"]) :where(img,video) {
      display: block !important; width: auto !important; max-width: var(--reader-image-width) !important;
      height: auto !important; max-height: none !important; margin: 0 auto !important;
      padding: 0 !important; border: 0 !important; object-fit: contain; }
    #reader-content[data-reader-layout="unified"] :is([data-reader-block="image"],[data-reader-block="figure"]) :where(img,video) + :where(img,video) {
      margin-top: var(--reader-image-gap) !important; }
    #reader-content[data-reader-layout="unified"] :is(img,video)[data-reader-media="block"] {
      display: block !important; width: auto !important; max-width: var(--reader-image-width) !important;
      height: auto !important; max-height: none !important; margin: var(--reader-image-gap) auto !important;
      padding: 0 !important; border: 0 !important; text-indent: 0 !important; object-fit: contain; }
    #reader-content[data-reader-layout="unified"] img[data-reader-media="inline"] {
      display: inline !important; height: 1em !important; width: auto !important; max-width: 2em !important;
      margin: 0 !important; vertical-align: text-bottom; }
    #reader-content[data-reader-layout="unified"] figcaption {
      color: inherit !important; opacity: .65; font-size: .85em !important;
      line-height: 1.5 !important; margin: .6em 0 0 !important; text-align: center !important; text-indent: 0 !important; }
    #reader-content[data-reader-layout="unified"] blockquote {
      margin: 1.4em 0 !important; padding: .15em 0 .15em 1.1em !important;
      border-left: 2px solid rgba(128,128,128,.3) !important; }
    #reader-content[data-reader-layout="unified"] :where(ul,ol) { margin: 0 0 var(--reader-paragraph) !important; padding-inline-start: 1.5em !important; }
    #reader-content[data-reader-layout="unified"] li { margin: 0 0 .35em !important; }
    #reader-content[data-reader-layout="unified"] [data-reader-whitespace="pre-wrap"] { white-space: pre-wrap !important; }
    #reader-content[data-reader-layout="unified"] [data-reader-whitespace="pre-line"] { white-space: pre-line !important; }
    #reader-content[data-reader-layout="unified"] [data-reader-whitespace="break-spaces"] { white-space: break-spaces !important; }
    #reader-content[data-reader-layout="unified"] [data-reader-whitespace="pre"] { white-space: pre !important; }
    #reader-content[data-reader-layout="unified"] > :first-child { margin-top: 0 !important; }
    """
}
