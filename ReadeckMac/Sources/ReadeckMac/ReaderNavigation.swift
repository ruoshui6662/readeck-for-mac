import Foundation

struct ReaderHeading: Codable, Identifiable, Equatable {
    let index: Int
    let level: Int
    let title: String
    var id: Int { index }
}

struct ReaderFindState: Codable, Equatable {
    var count: Int = 0
    var current: Int = 0
}

enum ReaderNavigationScript {
    /// Runs in WebKit's isolated client world. Ranges leave the saved article
    /// tree, annotation XPath selectors, and the user's selection untouched.
    static let bootstrap = #"""
    (() => {
        if(window.__readerNavigation) return;
        const names=['reader-find','reader-find-current'];
        let previousRoot=null, previousQuery='', current=0;
        const root=()=>document.getElementById('reader-content');
        const excluded='script,style,noscript,template,textarea,select,iframe,object,embed';
        const boundary='br,hr,img,video,audio';
        function clear() {
            for(const name of names) CSS.highlights?.delete(name);
            previousRoot=null;previousQuery='';current=0;
            return {count:0,current:0};
        }
        function hidden(element,style) {
            return element.hidden || style.display==='none' || style.contentVisibility==='hidden' || Number(style.opacity)===0;
        }
        // Each run contains adjacent inline text only. Block boxes and explicit
        // line breaks end a run, so words cannot bridge paragraphs or table cells.
        function textRuns(container) {
            const runs=[];
            let nodes=[], length=0;
            function flush() {
                if(nodes.length) runs.push(nodes);
                nodes=[];length=0;
            }
            function visit(element) {
                const style=getComputedStyle(element);
                if(element.matches(excluded) || hidden(element,style)) return;
                if(element.matches(boundary)) {flush();return;}
                const block=style.display!=='inline' && style.display!=='contents';
                if(block) flush();
                const visible=style.visibility!=='hidden' && style.visibility!=='collapse';
                const whitespace=['pre','pre-wrap','break-spaces'].includes(style.whiteSpace) ? 'preserve' :
                    style.whiteSpace==='pre-line' ? 'lines' : 'collapse';
                for(const child of element.childNodes) {
                    if(child.nodeType===Node.TEXT_NODE && visible && child.length) {
                        // Different whitespace policies cannot share a normalized
                        // search run without inventing spaces at their boundary.
                        if(nodes.length && nodes[0].whitespace!==whitespace) flush();
                        nodes.push({node:child,start:length,end:length+child.length,whitespace});
                        length+=child.length;
                    } else if(child.nodeType===Node.ELEMENT_NODE) visit(child);
                }
                if(block) flush();
            }
            // Ancestors outside the article can hide an otherwise visible root.
            for(let element=container.parentElement;element;element=element.parentElement) {
                if(hidden(element,getComputedStyle(element))) return [];
            }
            visit(container);flush();return runs;
        }
        function headingEntries() {
            const article=root();
            if(!article) return [];
            const entries=[];
            for(const node of article.querySelectorAll('h1,h2,h3,h4,h5,h6')) {
                const style=getComputedStyle(node);
                if(style.visibility==='hidden' || style.visibility==='collapse') continue;
                const title=textRuns(node).flat().map(part=>part.node.data).join('').replace(/\s+/g,' ').trim();
                if(!title || !Array.from(node.getClientRects()).some(rect=>rect.width>0 && rect.height>0)) continue;
                entries.push({node,index:entries.length,level:Number(node.tagName.slice(1)),title});
            }
            return entries;
        }
        function outline() {
            return headingEntries().map(({index,level,title})=>({index,level,title}));
        }
        // Geometry is read at the time of the query, so late images and font
        // changes cannot leave behind document offsets from a previous layout.
        function currentHeading(entries=headingEntries()) {
            if(!entries.length) return null;
            const threshold=Math.min(120,innerHeight*0.22);
            let active=entries[0].index;
            for(const entry of entries) {
                if(entry.node.getBoundingClientRect().top<=threshold) active=entry.index;
                else break;
            }
            const maximum=document.documentElement.scrollHeight-innerHeight;
            if(maximum>0 && scrollY>=maximum-2) active=entries[entries.length-1].index;
            return active;
        }
        let trackingTimer=0, lastSnapshot='';
        function publishOutline() {
            const entries=headingEntries();
            const snapshot={documentID:document.body.dataset.readerDocument,
                headings:entries.map(({index,level,title})=>({index,level,title})),current:currentHeading(entries)};
            const key=JSON.stringify(snapshot);
            if(key===lastSnapshot) return;
            lastSnapshot=key;
            window.webkit?.messageHandlers?.readerOutline?.postMessage(snapshot);
        }
        function scheduleOutline() {
            if(trackingTimer) return;
            // Bound layout reads on long articles. A timer also works when WebKit
            // suspends animation frames for an occluded reader window.
            trackingTimer=setTimeout(()=>{trackingTimer=0;publishOutline();},50);
        }
        window.addEventListener('scroll',scheduleOutline,{passive:true});
        window.addEventListener('resize',scheduleOutline,{passive:true});
        document.addEventListener('load',scheduleOutline,true);
        const layoutObserver=new ResizeObserver(scheduleOutline);
        layoutObserver.observe(document.body);
        document.fonts?.ready.then(scheduleOutline);
        scheduleOutline();
        function revealRect(rect) {
            if(!rect || !Number.isFinite(rect.top)) return false;
            const wasAdjusting=window.__readerAdjusting;
            window.__readerAdjusting=true;
            window.scrollBy(0,rect.top-Math.min(72,innerHeight/4));
            window.__readerReflow?.capturePosition();
            if(!wasAdjusting) setTimeout(()=>{window.__readerAdjusting=false;},80);
            return true;
        }
        function revealHeading(index) {
            if(!Number.isInteger(index) || index<0) return false;
            const heading=headingEntries()[index];
            return !!heading && revealRect(heading.node.getBoundingClientRect());
        }
        // Collapse rendered whitespace before folding case, keeping the original
        // UTF-16 span of every searchable character. Highlighting still covers
        // the saved text, including collapsed whitespace and surrogate pairs.
        function foldedText(text,whitespace='preserve') {
            let folded='', offset=0, pending=null, afterBreak=false;
            const starts=[], ends=[];
            function emit(scalar,start,end) {
                // Final and medial Greek sigma have the same caseless form.
                // A targeted fold preserves dotted İ's existing expansion map.
                const lower=scalar==='ς' ? 'σ' : scalar.toLowerCase();
                folded+=lower;
                for(let i=0;i<lower.length;i++) {starts.push(start);ends.push(end);}
            }
            for(const scalar of text) {
                const end=offset+scalar.length;
                const isSpace=/[\t\n\r\f ]/.test(scalar);
                const isBreak=/[\n\r\f]/.test(scalar);
                if(whitespace==='lines' && isBreak) {
                    // pre-line preserves line breaks and removes adjacent spaces.
                    pending=null;emit('\n',offset,end);afterBreak=true;
                } else if(whitespace!=='preserve' && isSpace) {
                    if(!afterBreak) {
                        if(pending) pending.end=end;
                        else pending={start:offset,end};
                    }
                } else {
                    if(pending) {emit(' ',pending.start,pending.end);pending=null;}
                    emit(scalar,offset,end);afterBreak=false;
                }
                offset+=scalar.length;
            }
            if(pending) emit(' ',pending.start,pending.end);
            return {folded,starts,ends};
        }
        function rangeFor(parts,start,end) {
            function endpoint(offset,inclusive) {
                let low=0,high=parts.length;
                while(low<high) {
                    const middle=(low+high)>>>1;
                    if(inclusive?parts[middle].end<offset:parts[middle].end<=offset) low=middle+1;
                    else high=middle;
                }
                return parts[low];
            }
            const first=endpoint(start,false);
            const last=endpoint(end,true);
            if(!first || !last) return null;
            const range=document.createRange();
            range.setStart(first.node,start-first.start);
            range.setEnd(last.node,end-last.start);
            return range;
        }
        function find(query,step=0) {
            const article=root();
            if(!article || typeof query!=='string' || !query.trim()) return clear();
            const needle=foldedText(query).folded;
            const ranges=[];
            // Rebuild ranges each time; typography and document replacements
            // must never reuse an offset into an obsolete text node.
            for(const parts of textRuns(article)) {
                const text=parts.map(part=>part.node.data).join('');
                const folded=foldedText(text,parts[0].whitespace);
                let from=0;
                while(from<=folded.folded.length-needle.length) {
                    const at=folded.folded.indexOf(needle,from);
                    if(at<0) break;
                    const range=rangeFor(parts,folded.starts[at],folded.ends[at+needle.length-1]);
                    if(range && Array.from(range.getClientRects()).some(rect=>rect.width>0 && rect.height>0)) ranges.push(range);
                    from=at+needle.length;
                }
            }
            if(!ranges.length) return clear();
            const same=previousRoot===article && previousQuery===needle;
            current=same && step!==0 ? ((current-1+(step<0?-1:1))%ranges.length+ranges.length)%ranges.length+1 : 1;
            previousRoot=article;previousQuery=needle;
            const highlight=new Highlight();
            highlight.priority=1;
            for(const range of ranges) highlight.add(range);
            CSS.highlights.set(names[0],highlight);
            const active=ranges[current-1];
            const activeHighlight=new Highlight(active);
            activeHighlight.priority=2;
            CSS.highlights.set(names[1],activeHighlight);
            const rect=Array.from(active.getClientRects()).find(rect=>rect.width>0 && rect.height>0);
            revealRect(rect);
            return {count:ranges.length,current};
        }
        // Clearing disconnected ranges also releases references when the article
        // is replaced without a navigation. Style-only changes preserve matches.
        const observer=new MutationObserver(records=>{
            scheduleOutline();
            if(previousRoot && (!previousRoot.isConnected || records.some(record=>record.type!=='attributes' && previousRoot.contains(record.target)))) clear();
        });
        observer.observe(document.body,{childList:true,characterData:true,attributes:true,attributeFilter:['hidden','style','class'],subtree:true});
        window.__readerNavigation={outline,currentHeading,find,revealHeading,clear};
    })();
    """#
}
