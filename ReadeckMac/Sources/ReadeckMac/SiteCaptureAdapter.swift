import Foundation
import WebKit

/// Reads a single already-loaded article. No feed requests, credentials or NAS API
/// are exposed to this page world. The output is sanitized again by the archive parser.
enum SiteCaptureAdapter {
    struct Snapshot: Sendable {
        let html: String
        let title: String
        let source: CaptureSourceURL
    }

    @MainActor
    static func snapshot(web: WKWebView, source: CaptureSourceURL) async throws -> Snapshot {
        let current = web.url?.absoluteString ?? source.original.absoluteString
        guard let resolved = try? CaptureSourceURL(current) else { throw WechatParseError.interactionRequired }
        let legacyCV = source.site == .bilibili && (source.articleID?.hasPrefix("cv") ?? false) && (resolved.articleID?.hasPrefix("opus") ?? false)
        guard resolved.site == source.site, source.allowsNavigation(to: resolved.original),
              source.articleID == nil || source.articleID == resolved.articleID || legacyCV else { throw WechatParseError.interactionRequired }
        guard let result = try await web.callAsyncJavaScript(snapshotScript,
            arguments: ["site": source.site.rawValue, "articleID": resolved.articleID ?? "", "expectedCV": legacyCV ? (source.articleID ?? "") : ""], in: nil, contentWorld: .page) as? [String: Any] else { throw WechatParseError.interactionRequired }
        if let error = result["error"] as? String { throw WechatParseError.parseError(error) }
        guard let html = result["html"] as? String, let title = result["title"] as? String,
              html.utf8.count <= CaptureLimits().maximumHTMLBytes else { throw WechatParseError.interactionRequired }
        return Snapshot(html: html, title: title, source: legacyCV ? source : resolved)
    }

    /// Snapshot only the normalized content, while WebKit supplies source-session
    /// image bytes (including cookies/referrer) in the WebArchive resource table.
    @MainActor
    static func capture(web: WKWebView, source: CaptureSourceURL,
                        progress: ((CaptureResourceReport) -> Void)? = nil) async throws -> Data {
        var snapshot: Snapshot?
        for attempt in 0..<20 {
            try Task.checkCancellation()
            do { snapshot = try await self.snapshot(web: web, source: source); break }
            catch WechatParseError.interactionRequired {
                if attempt == 19 { throw WechatParseError.interactionRequired }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        guard let snapshot else { throw WechatParseError.interactionRequired }
        _ = try await web.callAsyncJavaScript(installScript, arguments: ["html": snapshot.html], in: nil, contentWorld: .defaultClient)
        var result = Data()
        for attempt in 1...3 {
            try Task.checkCancellation()
            let html = try await web.callAsyncJavaScript(freezeScript, arguments: ["attempt": attempt], in: nil, contentWorld: .defaultClient) as? String ?? ""
            guard html.utf8.count <= CaptureLimits().maximumHTMLBytes, !html.isEmpty else { throw CaptureError.invalidPackage }
            let archive: Data = try await withCheckedThrowingContinuation { c in web.createWebArchiveData { c.resume(with: $0) } }
            guard archive.count <= CaptureLimits().maximumArchiveBytes,
                  var plist = try PropertyListSerialization.propertyList(from: archive, options: [], format: nil) as? [String: Any],
                  var main = plist["WebMainResource"] as? [String: Any] else { throw CaptureError.invalidPackage }
            main["WebResourceData"] = Data(html.utf8)
            main["WebResourceURL"] = snapshot.source.canonical.absoluteString
            plist["WebMainResource"] = main
            result = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            let report = try await Task.detached { try CaptureArticleParser.extract(archive: result, source: source, packageID: "probe").resourceReport }.value
            if let report { progress?(report) }
            if report?.issues.isEmpty != false { break }
        }
        return result
    }

    private static let installScript = #"""
    globalThis.__readeckCaptureAbort=false;
    const doc=new DOMParser().parseFromString(html,'text/html');
    const root=doc.getElementById('readeck-captured-content');
    if(!root)throw new Error('没有正文');
    document.getElementById('readeck-captured-content')?.remove();
    const copy=document.importNode(root,true);
    // The page stays usable for manual verification. Eager image requests still
    // run offscreen; source CSS cannot hide the images or select thumbnails.
    copy.style.cssText='position:fixed;left:-10000px;top:0;width:800px;display:block;';
    for(const img of copy.querySelectorAll('img')){img.loading='eager';img.removeAttribute('srcset');}
    document.body.append(copy);
    globalThis.__readeckSnapshotHead=doc.head.innerHTML;
    return true;
    """#

    private static let freezeScript = #"""
    const root=document.getElementById('readeck-captured-content');
    if(!root)throw new Error('正文不可用');
    const imgs=[...root.querySelectorAll('img')];
    if(imgs.length>100)throw new Error('正文图片数量超过100张');
    let cursor=0;
    async function worker(){while(cursor<imgs.length){
      const index=cursor++,img=imgs[index],source=img.getAttribute('src');
      if(globalThis.__readeckCaptureAbort)throw new Error('采集已取消');
      if(img.complete&&img.naturalWidth>0)continue;
      await new Promise(resolve=>{
        let timer;const end=()=>{clearTimeout(timer);img.removeEventListener('load',end);img.removeEventListener('error',end);resolve();};
        img.addEventListener('load',end,{once:true});img.addEventListener('error',end,{once:true});
        timer=setTimeout(end,5000);
        if(attempt>1 || img.complete){img.removeAttribute('src');img.setAttribute('src',source);}
      });
    }}
    await Promise.all([worker(),worker(),worker()]);
    if(globalThis.__readeckCaptureAbort)throw new Error('采集已取消');
    const copy=root.cloneNode(true);copy.removeAttribute('style');
    copy.setAttribute('data-readeck-attempt',String(attempt));
    for(const [i,img] of [...copy.querySelectorAll('img')].entries())img.setAttribute('data-readeck-resource-id','image-'+i);
    return '<!doctype html><html><head>'+globalThis.__readeckSnapshotHead+'</head><body>'+copy.outerHTML+'</body></html>';
    """#

    static let snapshotScript = #"""
    const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
    const visible=node=>!!node && getComputedStyle(node).display!=='none' && getComputedStyle(node).visibility!=='hidden' && node.getClientRects().length>0;
    const unwrap=value=>{for(let i=0;i<5 && value && typeof value==='object';i++){
      if(value.__v_isRef || value._rawValue || value._value) value=value._rawValue??value._value??value.value;
      else break;
    }return value;};
    const text=node=>(node?.textContent||'').trim();
    const imageURL=value=>{
      if(typeof value!=='string'||!value)return '';
      if(value.startsWith('data:image/'))return value.length<=17000000?value:'';
      try{const u=new URL(value,document.baseURI);if(!['http:','https:'].includes(u.protocol)||u.username||u.password)return '';
        const domains=site==='xiaohongshu'?['xhscdn.com','rednotecdn.com','xiaohongshu.com']:site==='ithome'?['ithome.com']:site==='douban'?['doubanio.com','douban.com']:site==='bilibili'?['hdslb.com','biliimg.com','bilibili.com']:['baidu.com','baidubce.com','bcebos.com','bdstatic.com'];
        if(!domains.some(d=>u.hostname===d||u.hostname.endsWith('.'+d)))return '';
        if(u.protocol==='http:')u.protocol='https:';
        return u.href;
      }catch{return '';}
    };
    let title='',author='',published='',body='';
    if(site==='xiaohongshu') {
      if(!articleID)return null;
      const state=unwrap(window.__INITIAL_STATE__);
      const map=unwrap(unwrap(state?.note)?.noteDetailMap);
      const entry=unwrap(map?.[articleID]);
      const note=unwrap(entry?.note??entry);
      if(note) {
        const id=String(note.noteId??note.note_id??articleID);
        if(id!==articleID)return null;
        if(note.type==='video')return {error:'首版仅支持小红书静态图文，暂不归档视频笔记。'};
        title=String(note.title||'');author=String(unwrap(note.user)?.nickname||'');
        const date=note.time??note.publishTime;
        if(date && Number.isFinite(Number(date))) {const d=new Date(Number(date));if(!isNaN(d))published=d.toISOString();}
        body=String(note.desc??note.description??'').split(/\r?\n/).map(line=>line?'<p>'+esc(line)+'</p>':'').join('');
        const images=unwrap(note.imageList??note.image_list);
        if(!Array.isArray(images))return {error:'未取得完整的图集数据，请完成页面加载后继续采集。'};
        if(images.length>100)return {error:'正文图片数量超过100张。'};
        for(let i=0;i<images.length;i++) {
          const image=unwrap(images[i]);const info=unwrap(image.infoList??image.info_list)||[];
          const preferred=Array.isArray(info)?info.find(v=>(v.imageScene??v.image_scene)==='WB_DFT'):null;
          const url=imageURL(image.urlDefault??image.url_default??preferred?.url??image.url??image.urlPre??image.url_pre);
          if(!url)return {error:'第 '+(i+1)+' 张图片缺少可用地址，请完成页面加载后重试。'};
          body+='<figure><img src="'+esc(url)+'" alt="图片 '+(i+1)+'">'+(image.livePhoto||image.live_photo?'<figcaption>实况照片的静态画面</figcaption>':'')+'</figure>';
        }
      } else {
        const root=Array.from(document.querySelectorAll('#noteContainer,.note-container')).find(visible);
        if(!root || root.querySelector('video'))return null;
        const declared=root.getAttribute('data-note-id')||root.getAttribute('note-id');
        if(declared!==articleID)return null;
        title=text(root.querySelector('#detail-title,.title'));
        const description=root.querySelector('#detail-desc,.desc');
        if(!title || !description)return null;
        author=text(root.querySelector('.author .username,.author-name'));
        body=text(description).split(/\r?\n/).map(line=>'<p>'+esc(line)+'</p>').join('');
        const slides=Array.from(root.querySelectorAll('.swiper-slide')).filter(n=>!n.classList.contains('swiper-slide-duplicate'));
        const indexed=new Map();
        for(const slide of slides){const index=slide.getAttribute('data-swiper-slide-index');if(index!==null && !indexed.has(index))indexed.set(index,slide);}
        const ordered=indexed.size===slides.length?[...indexed.entries()].sort((a,b)=>Number(a[0])-Number(b[0])).map(v=>v[1]):slides;
        const images=ordered.length?ordered.map(s=>s.querySelector('img')):Array.from(root.querySelectorAll('.media-container img,.note-slider img'));
        // A contiguous partial carousel is still partial: require a reliable total.
        const counter=text(root.querySelector('.fraction,.pagination-fraction,.swiper-pagination-fraction'));
        const total=Number(counter.match(/\/\s*(\d+)/)?.[1]||0);
        if(!images.length || !total || total!==images.length)return {error:'页面未提供完整图集，请等待图集加载后继续采集。'};
        for(let i=0;i<images.length;i++) {
          const img=images[i],url=imageURL(img?.currentSrc||img?.getAttribute('src'));
          if(!url)return {error:'第 '+(i+1)+' 张图片未取得，请重新采集。'};
          body+='<figure><img src="'+esc(url)+'" alt="图片 '+(i+1)+'"></figure>';
        }
      }
      if(!body)return null;
      if(!title)title='小红书图文';
    } else if(site==='douban' || site==='bilibili') {
      let root;
      if(site==='douban') {
        root=document.querySelector('#review-'+articleID+'-content .review-content');
        title=text(document.querySelector('h1'));
        author=root?.getAttribute('data-author')||'';
      } else {
        if(expectedCV && !((text(document.querySelector('.opus-module-copyright')).match(/\bcv[0-9]+\b/g)||[]).includes(expectedCV)))return null;
        root=document.querySelector('.opus-module-content');
        title=text(document.querySelector('.opus-module-title__inner,.opus-module-title'));
        author=text(document.querySelector('.opus-module-author__name'));
      }
      if(!root || !title || !text(root))return null;
      const copy=root.cloneNode(true);
      if(site==='bilibili') {
        for(const card of copy.querySelectorAll('.opus-para-link-card')) {
          const label=text(card.querySelector('.video-player-title,.video-card-player-title,.link-card-title'));
          const p=document.createElement('p');p.textContent=label;card.replaceWith(p);
        }
      }
      copy.querySelectorAll('script,style,iframe,video,audio,button,input,form,nav,aside,header,footer,.image-gif-pannel,.bili-dyn-pic__mask,.b-img__placeholder,.opus-text-rich-hl svg').forEach(n=>n.remove());
      for(const picture of copy.querySelectorAll('picture'))picture.querySelectorAll('source').forEach(n=>n.remove());
      for(const img of copy.querySelectorAll('img')) {
        const raw=img.getAttribute('data-original-url')||img.getAttribute('data-original')||img.getAttribute('data-src')||img.getAttribute('src');
        const url=imageURL(raw);
        if(!url)return {error:'正文图片地址不可用，请重新采集。'};
        img.setAttribute('src',url);img.removeAttribute('srcset');
      }
      for(const node of copy.querySelectorAll('*'))for(const attr of [...node.attributes])if(!['href','src','alt','title','colspan','rowspan'].includes(attr.name))node.removeAttribute(attr.name);
      body=copy.innerHTML;
    } else if(site==='ithome') {
      const root=document.querySelector('#paragraph');
      const heading=document.querySelector('h1');
      if(!root || !heading || !text(root))return null;
      title=text(heading);
      author=text(document.querySelector('#author_baidu'));
      const copy=root.cloneNode(true);
      copy.querySelectorAll('script,style,iframe,video,audio,button,input,form,nav,aside,header,footer,.tougao-user,[class*="recommend"],[class*="advert"]').forEach(n=>n.remove());
      for(const img of copy.querySelectorAll('img')) {
        const url=imageURL(img.getAttribute('data-original')||img.getAttribute('data-src')||img.getAttribute('src'));
        if(!url)return {error:'正文图片地址不可用，请重新采集。'};
        img.setAttribute('src',url);
        img.removeAttribute('srcset');
      }
      for(const node of copy.querySelectorAll('*'))for(const attr of [...node.attributes])if(!['href','src','alt','title','colspan','rowspan'].includes(attr.name))node.removeAttribute(attr.name);
      body=copy.innerHTML;
    } else if(site==='baike') {
      const root=Array.from(document.querySelectorAll('.main-content,[class*="mainContent"],[class*="lemmaMain"],main')).find(visible);
      const heading=document.querySelector('h1');
      if(!root||!heading)return null;
      title=text(heading); if(!title)return null;
      let copy;
      const content=root.querySelector('.J-lemma-content');
      if(content) {
        if(!text(content))return null;
        copy=document.createElement('div');
        for(const selector of ['.J-summary','.J-basic-info','.J-lemma-content','#J-lemma-reference']) {
          const block=root.querySelector(selector);if(block)copy.append(block.cloneNode(true));
        }
      } else copy=root.cloneNode(true);
      copy.querySelectorAll('script,style,iframe,video,audio,button,input,form,nav,aside,header,footer,.lemmaWgt-promotion,.lemma-subscribe,[class*="recommend"],[class*="Recommend"],[class*="promotion"],[class*="Promotion"],[class*="sideCatalog"],[class*="editTool"],[class*="edit-icon"],[class*="topTools"],[class*="hotspot"],[class*="lemmaStarMap"],[class*="albumList"],[class*="catalogWrapper"],.lemma-catalog').forEach(n=>n.remove());
      // Modern Baike stores lazy illustrations as JSON components, with no img
      // node until scrolled into view. Recover them in place, preserving order.
      for(const node of copy.querySelectorAll('[data-single-image]')) {
        let info;try{info=JSON.parse(node.getAttribute('data-single-image'));}catch{return {error:'正文图片组件数据不完整，请重新采集。'};}
        let url=imageURL(info.url);
        if(!url)return {error:'正文图片组件缺少可用地址，请重新采集。'};
        const original=new URL(url);
        const process=original.searchParams.get('x-bce-process')||'';
        // Only remove the known public thumbnail resize operation, never a
        // signature or arbitrary CDN parameter. NAS creates its reading copy.
        if(original.hostname==='bkimg.cdn.bcebos.com' && original.pathname.startsWith('/pic/') && process.startsWith('image/resize,') && [...original.searchParams.keys()].every(k=>k==='x-bce-process')) {
          original.searchParams.delete('x-bce-process');url=original.href;
        }
        const figure=document.createElement('figure'),img=document.createElement('img');img.src=url;img.alt=String(info.title||'');figure.append(img);
        if(info.title){const caption=document.createElement('figcaption');caption.textContent=String(info.title);figure.append(caption);}
        node.replaceWith(figure);
      }
      const basic=copy.querySelector('.J-basic-info');
      if(basic) {
        const table=document.createElement('table'),tbody=document.createElement('tbody');
        for(const dt of basic.querySelectorAll('dt')) {
          let dd=dt.nextElementSibling;while(dd&&dd.tagName!=='DD')dd=dd.nextElementSibling;
          if(!dd)continue;
          const row=document.createElement('tr'),key=document.createElement('th'),value=document.createElement('td');
          key.textContent=text(dt).replace(/\s+/g,' ');value.innerHTML=dd.innerHTML;row.append(key,value);tbody.append(row);
        }
        table.append(tbody);basic.replaceWith(table);
      }
      for(const element of [...copy.querySelectorAll('*')]) {
        if(['H1'].includes(element.tagName)){element.remove();continue;}
        if(element.matches('[class*="para-title"],[class*="paraTitle"]')) {
          const existing=element.querySelector('h2,h3,h4,h5,h6');
          const raw=Number(element.getAttribute('data-level'));
          const level=raw>0?Math.min(6,raw+1):(/level[-_]?3/.test(element.className)?3:2);
          const h=document.createElement('h'+level);h.textContent=existing?text(existing):text(element);element.replaceWith(h);
        }
        if(element.matches('[class*="referenceTitle"]')){const h=document.createElement('h2');h.textContent=text(element);element.replaceWith(h);}
      }
      copy.querySelectorAll('svg,[data-tts-catalog],[class*="editLemma"],[class*="gotopWrapper"]').forEach(n=>n.remove());
      for(const img of copy.querySelectorAll('img')) {
        // data-lazy is sometimes a boolean marker rather than an image URL.
        const marker=img.getAttribute('data-lazy')||'';
        const lazyURL=/^(?:https?:\/\/|\/\/|\/|\.\/|\.\.\/|data:image\/)/i.test(marker)?marker:'';
        const url=imageURL(img.getAttribute('data-src')||img.getAttribute('data-original')||img.getAttribute('data-lazy-src')||lazyURL||img.getAttribute('src'));
        if(!url)return {error:'词条正文中有图片尚未加载，请完成页面加载后继续采集。'};
        img.setAttribute('src',url);
      }
      for(const node of copy.querySelectorAll('*'))for(const attr of [...node.attributes])if(!['href','src','alt','title','colspan','rowspan'].includes(attr.name))node.removeAttribute(attr.name);
      body=copy.innerHTML;
      if(!text(copy))return null;
    } else return null;
    const siteName=site==='baike'?'百度百科':site==='ithome'?'IT之家':site==='douban'?'豆瓣电影':site==='bilibili'?'哔哩哔哩':'小红书';
    const html='<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><title>'+esc(title)+'</title><meta name="author" content="'+esc(author)+'"><meta property="og:site_name" content="'+siteName+'">'+(published?'<meta property="article:published_time" content="'+esc(published)+'">':'')+'</head><body><div id="readeck-captured-content">'+body+'</div></body></html>';
    if(html.length>8000000)return {error:'正文超过大小上限。'};
    return {title,html};
    """#
}
