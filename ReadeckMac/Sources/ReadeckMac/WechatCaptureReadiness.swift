import Foundation

enum WechatCaptureReadiness {
    /// Independent implementation using public DOM APIs. All source addresses
    /// remain in the isolated browser world; only counts/timing enter the archive.
    static let script = "const capturePolicy=" + CaptureResourcePolicy.current.scriptJSON + ";\n" + #"""
    globalThis.__readeckCaptureAbort=false;
    globalThis.__readeckResources=new Map();
    if(normalized) {
      document.querySelector('#readeck-captured-content')?.remove();
      const host=document.createElement('div');host.innerHTML=normalized;document.body.appendChild(host);
    }
    const root=document.querySelector('#readeck-captured-content, #js_content');
    if(!root || !(root.textContent.trim() || root.querySelector('img[data-src],img[src]'))) return false;
    const options=typeof readinessOptions==='object'?readinessOptions:{};
    const stableMS=Math.max(20,Math.min(1000,Number(options.stableMS)||800));
    const maximumMS=Math.max(50,Math.min(10000,Number(options.maximumMS)||10000));
    const widgetSelector=capturePolicy.widgets.map(rule=>rule.selector).join(',');
    const inScope=node=>!node.closest(widgetSelector);
    const started=performance.now();let lastChange=started, signature='', settled=false, scrolls=0;
    const original={x:scrollX,y:scrollY};const backgrounds=new Map();let backgroundList=[],lastStyleScan=-Infinity;
    const placeholderHashes=new Map();
    async function knownPlaceholder(el,url) {
      if(!el.matches(capturePolicy.placeholderImageSelector)||!url.toLowerCase().startsWith('data:image/svg+xml')||url.length>64000)return false;
      if(placeholderHashes.has(url))return placeholderHashes.get(url);
      let known=false;
      try {
        const comma=url.indexOf(','),head=url.slice(0,comma).toLowerCase(),payload=decodeURIComponent(url.slice(comma+1));
        const bytes=head.endsWith(';base64')?Uint8Array.from(atob(payload),c=>c.charCodeAt(0)):new TextEncoder().encode(payload);
        if(bytes.length<=16384&&globalThis.crypto?.subtle) {
          const digest=await crypto.subtle.digest('SHA-256',bytes);
          const hash=Array.from(new Uint8Array(digest),b=>b.toString(16).padStart(2,'0')).join('');
          known=capturePolicy.placeholderSVGHashes.includes(hash);
        }
      } catch {}
      placeholderHashes.set(url,known);return known;
    }
    const observer=new MutationObserver(changes=>{
      if(changes.some(change=>inScope(change.target.nodeType===1?change.target:change.target.parentElement)))lastChange=performance.now();
    });
    observer.observe(root,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['src','srcset','data-src','style','class']});
    let imgs=[],failedImages=0,pendingImages=0;
    try {
      while(true) {
        if(globalThis.__readeckCaptureAbort)throw new Error('采集已取消');
        imgs=Array.from(root.querySelectorAll('img')).filter(inScope);
        if(imgs.length>100)throw new Error('正文图片数量超过100张');
        for(const img of imgs) {
          const lazy=img.getAttribute('data-src');
          if(lazy){const url=new URL(lazy,document.baseURI).href;if(img.src!==url)img.src=url;}
          img.loading='eager';
        }
        if(performance.now()-lastStyleScan>=250) {
        backgroundList=[];lastStyleScan=performance.now();
        const nodes=[root,...root.querySelectorAll('*')].filter(inScope);
        if(nodes.length>20000)throw new Error('正文节点数量超过采集上限');
        for(const el of nodes) {
          const css=getComputedStyle(el).backgroundImage, frozen=[];
          for(const match of css.matchAll(/url\(\s*(?:"([^"]*)"|'([^']*)'|([^)]*))\s*\)/g)) {
            const value=(match[1]||match[2]||match[3]||'').trim();
            if(!value)continue;
            const url=new URL(value,document.baseURI).href;
            if(await knownPlaceholder(el,url))continue;
            if(backgroundList.length>=100)throw new Error('正文背景图片数量超过100张');
            if(!backgrounds.has(url)){const probe=new Image();probe.src=url;backgrounds.set(url,probe);}
            const id='background-'+backgroundList.length;
            frozen.push({id,url});backgroundList.push({id,url});
          }
          if(frozen.length || el.hasAttribute('style') || el.hasAttribute('data-readeck-backgrounds'))
            el.setAttribute('data-readeck-backgrounds',JSON.stringify(frozen));
        }
        }
        const urls=backgroundList.map(item=>item.url);
        const next=imgs.map(img=>[img.currentSrc,img.src,img.srcset].join('|')).concat(urls).join('\n');
        if(next!==signature){signature=next;lastChange=performance.now();}
        const all=[...imgs,...urls.map(url=>backgrounds.get(url))];
        pendingImages=all.filter(img=>!img.complete).length;
        failedImages=all.filter(img=>img.complete&&img.naturalWidth===0&&img.getAttribute('src')).length;
        const now=performance.now();
        if(now-lastChange>=stableMS && pendingImages===0){settled=true;break;}
        if(now-started>=maximumMS)break;
        // Some templates only request images after entering the viewport.
        if(pendingImages && scrolls<12 && now-started>scrolls*300) {
          const box=root.getBoundingClientRect();
          scrollTo(original.x,Math.max(0,scrollY+box.top+box.height*(++scrolls/12)-innerHeight));
        }
        await new Promise(resolve=>setTimeout(resolve,50));
      }
      imgs.forEach((img,index)=>{const selected=img.currentSrc||img.getAttribute('src');if(selected){
        const id='image-'+index;img.setAttribute('data-readeck-resource-id',id);img.setAttribute('data-readeck-src',selected);
        globalThis.__readeckResources.set(id,{node:img,source:selected});
      }});
      for(const {id,url} of backgroundList)globalThis.__readeckResources.set(id,{node:backgrounds.get(url),source:url});
      root.setAttribute('data-readeck-policy-version',String(capturePolicy.version));
      root.setAttribute('data-readeck-image-count',String(imgs.length));
      root.setAttribute('data-readeck-background-count',String(backgroundList.length));
      root.setAttribute('data-readeck-attempt',String(typeof captureAttempt==='number'?captureAttempt:1));
      root.setAttribute('data-readeck-readiness',JSON.stringify({settled,failedImages,pendingImages,milliseconds:Math.round(performance.now()-started)}));
      return true;
    } finally {observer.disconnect();scrollTo(original.x,original.y);backgrounds.clear();}
    """#
}
