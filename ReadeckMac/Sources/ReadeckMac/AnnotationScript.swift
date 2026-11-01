import Foundation

/// Executes in WKContentWorld.defaultClient, while article JavaScript stays disabled.
/// Paths are relative to the article fragment and offsets count Unicode scalars,
/// matching Readeck's annotate package rather than DOM UTF-16 offsets.
enum AnnotationScript {
    static let bootstrap = #"""
    (() => {
        const root = document.getElementById('reader-content');
        if (!root || window.__readerAnnotations) return;

        // The article API can return server-rendered annotations. Their note icons
        // are extra text; their highlight wrappers are absent in the source XPath.
        root.querySelectorAll('rd-annotation[data-annotation-note]').forEach(node => node.remove());
        Array.from(root.querySelectorAll('rd-annotation')).reverse().forEach(node => {
            node.replaceWith(...node.childNodes);
        });
        root.normalize();

        const palette = {yellow: '#f5d75b99', red: '#f2939299', blue: '#83b9f499', green: '#9bce8199'};
        const style = document.createElement('style');
        style.id = 'reader-annotation-style';
        style.textContent = Object.entries(palette).map(([color, value]) =>
            `::highlight(reader-annotation-${color}) { background-color: ${value}; }`
        ).join('\n') + '\n::highlight(reader-annotation-note) { text-decoration: underline; text-decoration-style: dotted; }\n::highlight(reader-annotation-focus) { background-color: #f5c242bb; }';
        // Native WebKit selection fills paragraph gaps out to the document edge.
        // Keep the real Selection for copy/accessibility, paint only text ranges.
        style.textContent += '\n::selection { background-color: transparent !important; color: inherit; }\n::highlight(reader-selection) { background-color: #8bbcf478; }';
        document.head.appendChild(style);

        let rendered = [];
        let pointerPressed = false;
        let releasePoint = null;
        let reportTimer = null;
        let lastReport;

        function excluded(node) {
            const element = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
            return !!element?.closest('script,style,noscript,template');
        }

        function textNodes(element, onlyReadable = false) {
            const result = [];
            const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
            while (walker.nextNode()) {
                if (!onlyReadable || !excluded(walker.currentNode)) result.push(walker.currentNode);
            }
            return result;
        }

        function compare(a, aOffset, b, bOffset) {
            const first = document.createRange();
            const second = document.createRange();
            first.setStart(a, aOffset); first.collapse(true);
            second.setStart(b, bOffset); second.collapse(true);
            return first.compareBoundaryPoints(Range.START_TO_START, second);
        }

        function selector(node, offset) {
            const element = node.parentElement;
            const names = [];
            for (let current = element; current && current !== root; current = current.parentElement) {
                let index = 1;
                for (let sibling = current.previousElementSibling; sibling; sibling = sibling.previousElementSibling) {
                    if (sibling.localName === current.localName) index++;
                }
                names.unshift(`${current.localName}[${index}]`);
            }
            let runes = 0;
            for (const text of textNodes(element)) {
                if (text === node) {
                    runes += Array.from(text.data.slice(0, offset)).length;
                    break;
                }
                runes += Array.from(text.data).length;
            }
            // The server prefixes selectors with './'; './.' addresses the root.
            return {path: names.join('/') || '.', offset: runes};
        }

        function selectedTextRanges() {
            const selected = document.getSelection();
            if (!selected || selected.rangeCount !== 1 || selected.isCollapsed) return [];
            const source = selected.getRangeAt(0);
            if (!source.intersectsNode(root)) return [];
            if (root.contains(source.startContainer) && excluded(source.startContainer)) return [];
            if (root.contains(source.endContainer) && excluded(source.endContainer)) return [];
            const ranges = [];
            // A range per text node avoids native block/paragraph gap rectangles.
            // Element offsets and backward drags are normalized by boundary order.
            for (const node of textNodes(root, true)) {
                if (compare(node, node.length, source.startContainer, source.startOffset) <= 0) continue;
                if (compare(node, 0, source.endContainer, source.endOffset) >= 0) break;
                const start = node === source.startContainer ? source.startOffset : 0;
                const end = node === source.endContainer ? source.endOffset : node.length;
                if (start >= end) continue;
                const range = document.createRange();
                range.setStart(node, start); range.setEnd(node, end);
                ranges.push(range);
            }
            return ranges;
        }

        function paintSelection(ranges) {
            if (!ranges.length) { CSS.highlights.delete('reader-selection'); return; }
            const highlight = new Highlight(...ranges);
            highlight.priority = 10;
            CSS.highlights.set('reader-selection', highlight);
        }

        function selection() {
            const ranges = selectedTextRanges();
            paintSelection(ranges);
            if (!ranges.length) return null;
            const start = {node: ranges[0].startContainer, offset: ranges[0].startOffset};
            const lastRange = ranges.at(-1);
            const end = {node: lastRange.endContainer, offset: lastRange.endOffset};
            const range = document.createRange();
            range.setStart(start.node, start.offset); range.setEnd(end.node, end.offset);
            const text = range.toString();
            if (!text.trim()) return null;
            const first = selector(start.node, start.offset);
            const last = selector(end.node, end.offset);
            // Ignore whitespace-only DOM ranges when choosing a visual anchor.
            const rects=ranges.flatMap(part=>part.toString().trim()?Array.from(part.getClientRects()):[])
                .filter(rect=>rect.width>0&&rect.height>0&&rect.bottom>0&&rect.top<innerHeight&&rect.right>0&&rect.left<innerWidth);
            let anchor=null;
            if(rects.length) {
                const selected=document.getSelection();
                const backward=selected.focusNode && compare(selected.focusNode,selected.focusOffset,start.node,start.offset)<=0;
                let focus=backward?rects[0]:rects.at(-1);
                let pointer=null;
                if(releasePoint) {
                    const distance=r=>Math.max(r.left-releasePoint.x,releasePoint.x-r.right,0)**2+Math.max(r.top-releasePoint.y,releasePoint.y-r.bottom,0)**2;
                    const nearest=rects.reduce((a,b)=>distance(a)<=distance(b)?a:b);
                    if(distance(nearest)<=Math.max(24,nearest.height)**2){focus=nearest;pointer=releasePoint;}
                }
                // Keyboard selections have no release point; keep the toolbar
                // outside the whole selection when AppKit flips its placement.
                const top=Math.max(0,Math.min(...rects.map(r=>r.top)));
                const bottom=Math.min(innerHeight,Math.max(...rects.map(r=>r.bottom)));
                const y=pointer&&bottom-top>120?Math.max(0,focus.top):top;
                const end=pointer&&bottom-top>120?Math.min(innerHeight,focus.bottom):bottom;
                const x=Math.max(1,Math.min(innerWidth-2,pointer?pointer.x:(backward?focus.left:focus.right)));
                anchor={x,y,width:1,height:end-y,viewportWidth:innerWidth,viewportHeight:innerHeight,
                        preferredSide:'above'};
                if(pointer){anchor.pointerX=pointer.x;anchor.pointerY=pointer.y;}
            }
            return {start_selector: first.path, start_offset: first.offset,
                    end_selector: last.path, end_offset: last.offset, text, anchor};
        }

        function resolveElement(path) {
            if (path === '.') return root;
            if (typeof path !== 'string' || !/^[a-z][a-z0-9-]*\[[1-9][0-9]*\](\/[a-z][a-z0-9-]*\[[1-9][0-9]*\])*$/.test(path)) return null;
            let element = root;
            for (const segment of path.split('/')) {
                const [, name, index] = segment.match(/^([a-z][a-z0-9-]*)\[([1-9][0-9]*)\]$/);
                element = Array.from(element.children).filter(child => child.localName === name)[Number(index) - 1];
                if (!element || excluded(element)) return null;
            }
            return element;
        }

        function boundary(path, offset, isStart) {
            if (!Number.isSafeInteger(offset) || offset < 0) return null;
            const element = resolveElement(path);
            if (!element) return null;
            const nodes = textNodes(element);
            let consumed = 0;
            for (let i = 0; i < nodes.length; i++) {
                const node = nodes[i];
                const runes = Array.from(node.data);
                const next = consumed + runes.length;
                // Readeck advances start boundaries at the end of a text node.
                if (offset <= next && !(isStart && offset === next && i + 1 < nodes.length)) {
                    if (excluded(node)) return null;
                    return {node, offset: runes.slice(0, offset - consumed).join('').length};
                }
                consumed = next;
            }
            return null;
        }

        function annotationRange(item) {
            if (!item || typeof item.id !== 'string') return null;
            const start = boundary(item.start_selector, item.start_offset, true);
            const end = boundary(item.end_selector, item.end_offset, false);
            if (!start || !end || compare(start.node, start.offset, end.node, end.offset) >= 0) return null;
            const range = document.createRange();
            range.setStart(start.node, start.offset); range.setEnd(end.node, end.offset);
            return range;
        }

        function render(items) {
            rendered = [];
            const groups = Object.fromEntries(Object.keys(palette).map(color => [color, []]));
            const notes = [];
            for (const item of Array.isArray(items) ? items : []) {
                const range = annotationRange(item);
                if (!range) continue;
                rendered.push({id: item.id, range});
                const color = Object.hasOwn(palette, item.color) ? item.color : 'yellow';
                groups[color].push(range);
                if (typeof item.note === 'string' && item.note.trim()) notes.push(range);
            }
            // CSS Highlight API is available on the minimum supported macOS 26.
            // It keeps source elements and text nodes intact, including overlaps.
            for (const [color, ranges] of Object.entries(groups)) {
                const key = `reader-annotation-${color}`;
                if (ranges.length) CSS.highlights.set(key, new Highlight(...ranges));
                else CSS.highlights.delete(key);
            }
            if (notes.length) CSS.highlights.set('reader-annotation-note', new Highlight(...notes));
            else CSS.highlights.delete('reader-annotation-note');
            return rendered.length;
        }

        function reveal(id) {
            const item=rendered.find(item=>item.id===id);
            if (!item) return false;
            const rect=item.range.getBoundingClientRect();
            window.scrollBy({top:rect.top-innerHeight/3,behavior:'instant'});
            CSS.highlights.set('reader-annotation-focus',new Highlight(item.range));
            setTimeout(()=>CSS.highlights.delete('reader-annotation-focus'),1200);
            return true;
        }

        function post(name, body) {
            window.webkit?.messageHandlers?.[name]?.postMessage(body);
        }

        function reportSelection() {
            // Paint continuously during dragging; show the popup only on release.
            paintSelection(selectedTextRanges());
            clearTimeout(reportTimer);
            reportTimer = setTimeout(() => {
                if (pointerPressed) return;
                const value = selection();
                const encoded = JSON.stringify(value);
                if (encoded !== lastReport) {
                    lastReport = encoded;
                    post('annotationSelection', value);
                }
            }, 0);
        }

        document.addEventListener('pointerdown', () => { pointerPressed = true; releasePoint=null; });
        document.addEventListener('pointerup', event => { pointerPressed = false; releasePoint={x:event.clientX,y:event.clientY}; reportSelection(); });
        document.addEventListener('pointercancel', () => { pointerPressed = false; releasePoint=null; reportSelection(); });
        document.addEventListener('keydown',()=>{releasePoint=null;});
        document.addEventListener('selectionchange', reportSelection);
        window.addEventListener('scroll',()=>{releasePoint=null;post('annotationSelection',null);},{passive:true});
        window.addEventListener('resize',()=>post('annotationSelection',null));
        root.addEventListener('contextmenu', event => {
            const value=selection();
            if (!value) return;
            event.preventDefault();
            if(event.clientX||event.clientY)value.anchor={x:event.clientX,y:event.clientY,width:1,height:1,viewportWidth:innerWidth,viewportHeight:innerHeight,pointerX:event.clientX,pointerY:event.clientY};
            post('annotationContext',value);
        });
        root.addEventListener('click', event => {
            if (document.getSelection()?.isCollapsed === false) return;
            for (const annotation of rendered.slice().reverse()) {
                if (Array.from(annotation.range.getClientRects()).some(rect =>
                    event.clientX >= rect.left && event.clientX <= rect.right &&
                    event.clientY >= rect.top && event.clientY <= rect.bottom
                )) {
                    post('annotationTap', {id: annotation.id});
                    break;
                }
            }
        });
        window.__readerAnnotations = Object.freeze({selection, render, reveal});
    })();
    """#
}
