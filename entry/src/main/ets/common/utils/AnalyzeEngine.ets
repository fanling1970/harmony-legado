/**
 * AnalyzeEngine —— 本地书源规则解析引擎（替代已下线的远程 LegadoServer）
 * 支持规则子集：
 *  HTML：class.xxx.n / tag.xxx.n / id.xxx / [attr] 选择器链（@分隔），终点 text / href 等属性
 *  JSON：$.a.b / [*] / [n] / ..key 递归 的 JSONPath 子集
 *  组合：||（或）、##regex###替换（正则剔除）、&&（简化取第一段）
 * 不支持：@js / <js> / java. 等 JS 规则（调用前用 isJsRule 判断并给出提示）
 */

const VOID_TAGS: string[] = ['br', 'img', 'input', 'meta', 'link', 'hr', 'area', 'base', 'col', 'embed', 'source',
  'track', 'wbr'];

/** 简易 HTML DOM 节点 */
export class HtmlNode {
  tag: string = '';
  attrs: Map<string, string> = new Map();
  children: HtmlNode[] = [];
  parent: HtmlNode | null = null;
  text: string = '';
  isText: boolean = false;

  static textNode(t: string): HtmlNode {
    const n = new HtmlNode();
    n.isText = true;
    n.text = t;
    return n;
  }

  attr(name: string): string {
    const v = this.attrs.get(name);
    return v ?? '';
  }

  /** 聚合本节点及后代的全部文本 */
  innerText(): string {
    if (this.isText) {
      return this.text;
    }
    let out = '';
    for (const c of this.children) {
      if (c.isText) {
        out += c.text;
      } else if (c.tag === 'br') {
        out += '\n';
      } else {
        out += c.innerText();
      }
      if (!c.isText && c.tag !== 'br' && (c.tag === 'p' || c.tag === 'div' || c.tag === 'li' || c.tag === 'h1' ||
        c.tag === 'h2' || c.tag === 'h3' || c.tag === 'h4')) {
        out += '\n';
      }
    }
    return out;
  }

  /** 深度优先收集后代元素；tagName 为空收集全部元素 */
  descendants(tagName: string): HtmlNode[] {
    const out: HtmlNode[] = [];
    const walk = (node: HtmlNode) => {
      for (const c of node.children) {
        if (c.isText) {
          continue;
        }
        if (tagName === '' || c.tag === tagName) {
          out.push(c);
        }
        walk(c);
      }
    };
    walk(this);
    return out;
  }
}

/** 解码常见 HTML 实体 */
function decodeEntities(s: string): string {
  return s
    .replace(/&nbsp;/gi, ' ')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'")
    .replace(/&apos;/gi, "'")
    .replace(/&#(\d+);/g, (_m: string, d: string): string => String.fromCharCode(parseInt(d, 10)))
    .replace(/&#x([0-9a-fA-F]+);/g, (_m: string, d: string): string => String.fromCharCode(parseInt(d, 16)))
    .replace(/&amp;/gi, '&');
}

/** 解析属性串 */
function parseAttrs(attrStr: string, map: Map<string, string>) {
  const re = /([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/g;
  let m = re.exec(attrStr);
  while (m) {
    const key = m[1].toLowerCase();
    const val = decodeEntities(m[2] ?? m[3] ?? m[4] ?? '');
    map.set(key, val);
    m = re.exec(attrStr);
  }
}

/**
 * 解析 HTML 为节点树。非严格容错实现，适配常见小说站。
 */
export function parseHtml(html: string): HtmlNode {
  let src = html;
  src = src.replace(/<!--[\s\S]*?-->/g, '');
  src = src.replace(/<script[\s\S]*?<\/script>/gi, '');
  src = src.replace(/<style[\s\S]*?<\/style>/gi, '');
  const root = new HtmlNode();
  root.tag = 'root';
  let cur: HtmlNode = root;
  let i = 0;
  let textBuf = '';
  const flushText = () => {
    if (textBuf.trim().length > 0) {
      const t = HtmlNode.textNode(decodeEntities(textBuf.replace(/\s+/g, ' ')));
      t.parent = cur;
      cur.children.push(t);
    }
    textBuf = '';
  };
  while (i < src.length) {
    const ch = src[i];
    if (ch === '<') {
      // 找配对的 '>'，跳过属性中的引号内容
      let j = i + 1;
      let inQ = '';
      while (j < src.length) {
        const c = src[j];
        if (inQ !== '') {
          if (c === inQ) {
            inQ = '';
          }
        } else if (c === '"' || c === "'") {
          inQ = c;
        } else if (c === '>') {
          break;
        }
        j++;
      }
      if (j >= src.length) {
        textBuf += src.slice(i);
        i = src.length;
        continue;
      }
      const tagStr = src.slice(i + 1, j).trim();
      flushText();
      if (tagStr.startsWith('/')) {
        // 闭合标签：回退到同名祖先
        const closeTag = tagStr.slice(1).trim().toLowerCase();
        let p: HtmlNode | null = cur;
        while (p && p.parent && p.tag !== closeTag) {
          p = p.parent;
        }
        if (p && p.parent) {
          cur = p.parent;
        }
      } else if (!tagStr.startsWith('!') && !tagStr.startsWith('?')) {
        const nameMatch = /^([a-zA-Z][^\s/>]*)/.exec(tagStr);
        if (nameMatch) {
          const tag = nameMatch[1].toLowerCase();
          const node = new HtmlNode();
          node.tag = tag;
          parseAttrs(tagStr.slice(nameMatch[1].length), node.attrs);
          node.parent = cur;
          cur.children.push(node);
          const selfClose = tagStr.endsWith('/') || VOID_TAGS.includes(tag);
          if (!selfClose) {
            cur = node;
          }
        }
      }
      i = j + 1;
    } else {
      textBuf += ch;
      i++;
    }
  }
  flushText();
  return root;
}

/** 规则是否依赖 JS 引擎（本地不支持） */
export function isJsRule(rule?: string): boolean {
  if (!rule) {
    return false;
  }
  const r = rule.toLowerCase();
  return r.includes('@js:') || r.includes('<js>') || r.includes('java.') || r.includes('eval(') ||
    r.includes('@cache:') || r.includes('@put:') || r.includes('@base64');
}

/** 内容看起来是否 JSON */
export function looksLikeJson(text: string): boolean {
  const t = text.trim();
  return t.startsWith('{') || t.startsWith('[');
}

/** 解析规则字符串里 @ 分段（保留 [attr] 里的点） */
function splitAtRule(rule: string): string[] {
  const parts: string[] = [];
  let cur = '';
  let depth = 0;
  for (let i = 0; i < rule.length; i++) {
    const c = rule[i];
    if (c === '[') {
      depth++;
    }
    if (c === ']') {
      depth--;
    }
    if (c === '@' && depth === 0) {
      parts.push(cur);
      cur = '';
    } else {
      cur += c;
    }
  }
  parts.push(cur);
  return parts;
}

/** 拆分 "选择器.索引" 尾部 */
function segBaseName(seg: string): string {
  const dot = seg.lastIndexOf('.');
  if (dot > 0 && dot < seg.length - 1) {
    const tail = seg.slice(dot + 1);
    if (/^\d+$/.test(tail)) {
      return seg.slice(0, dot);
    }
  }
  return seg;
}

/** 拆分 "选择器.索引" 尾部的数字索引（无则 -1） */
function segIndexNum(seg: string): number {
  const dot = seg.lastIndexOf('.');
  if (dot > 0 && dot < seg.length - 1) {
    const tail = seg.slice(dot + 1);
    if (/^\d+$/.test(tail)) {
      return parseInt(tail, 10);
    }
  }
  return -1;
}

/** 按 HTML 选择器段过滤候选集合 */
function applyHtmlSeg(cands: HtmlNode[], seg: string): HtmlNode[] {
  const base = segBaseName(seg);
  const index = segIndexNum(seg);
  let result: HtmlNode[] = [];
  if (base.startsWith('class.')) {
    const cls = base.slice(6);
    for (const node of cands) {
      for (const d of node.descendants('')) {
        const own = d.attrs.get('class') ?? '';
        if (own.split(/\s+/).includes(cls)) {
          result.push(d);
        }
      }
    }
  } else if (base.startsWith('tag.')) {
    const tname = base.slice(4);
    for (const node of cands) {
      for (const d of node.descendants(tname)) {
        result.push(d);
      }
    }
  } else if (base.startsWith('id.')) {
    const idv = base.slice(3);
    for (const node of cands) {
      for (const d of node.descendants('')) {
        if (d.attr('id') === idv) {
          result.push(d);
        }
      }
    }
  } else if (base.startsWith('children')) {
    for (const node of cands) {
      for (const c of node.children) {
        if (!c.isText) {
          result.push(c);
        }
      }
    }
  } else {
    // 裸标签名，如 a[data-bid] / li
    let tname = base;
    let needAttr = '';
    const bm = /\[([-a-zA-Z0-9_:]+)\]$/.exec(base);
    if (bm) {
      tname = base.slice(0, base.length - bm[0].length);
      needAttr = bm[1].toLowerCase();
    }
    for (const node of cands) {
      const selfMatch: HtmlNode[] = [];
      if (node.tag === tname) {
        selfMatch.push(node);
      }
      for (const d of node.descendants(tname)) {
        selfMatch.push(d);
      }
      for (const d of selfMatch) {
        if (needAttr === '' || d.attrs.has(needAttr)) {
          result.push(d);
        }
      }
    }
  }
  if (index >= 0 && index < result.length) {
    return [result[index]];
  }
  if (index >= 0) {
    return [];
  }
  return result;
}

/** JSON 递归按 key 收集 */
function jsonFindByKey(obj: Object | null, key: string, out: Object[], deep: boolean) {
  if (obj === null || obj === undefined) {
    return;
  }
  if (Array.isArray(obj)) {
    const arr = obj as Object[];
    for (let i = 0; i < arr.length; i++) {
      jsonFindByKey(arr[i], key, out, deep);
    }
    return;
  }
  if (typeof obj !== 'object') {
    return;
  }
  const rec = obj as Record<string, Object>;
  const keys = Object.keys(rec);
  if (keys.includes(key)) {
    out.push(rec[key]);
  }
  if (deep) {
    for (let i = 0; i < keys.length; i++) {
      jsonFindByKey(rec[keys[i]], key, out, deep);
    }
  }
}

/** 从单个对象按 "name[idx][idx]" 路径取值追加到 out */
function jsonNavigate(obj: Object | null, path: string, out: Object[]) {
  if (obj === null || obj === undefined || typeof obj !== 'object') {
    return;
  }
  const am = /^([^[]*)((?:\[[^\]]*\])*)$/.exec(path);
  if (!am) {
    return;
  }
  let val: Object | null = null;
  if (Array.isArray(obj)) {
    const arr = obj as Object[];
    const n = parseInt(am[1], 10);
    if (!isNaN(n) && n < arr.length) {
      val = arr[n];
    }
  } else {
    const rec = obj as Record<string, Object>;
    const keys = Object.keys(rec);
    if (keys.includes(am[1])) {
      val = rec[am[1]];
    }
  }
  if (val === null) {
    return;
  }
  const idxStr = am[2];
  if (!idxStr) {
    out.push(val);
    return;
  }
  const idxs: string[] = [];
  const re = /\[([^\]]*)\]/g;
  let mm = re.exec(idxStr);
  while (mm) {
    idxs.push(mm[1]);
    mm = re.exec(idxStr);
  }
  let stack: Object[] = [val];
  for (const idx of idxs) {
    const nextStack: Object[] = [];
    for (const cur of stack) {
      if (Array.isArray(cur)) {
        const ca = cur as Object[];
        if (idx === '*') {
          for (let i = 0; i < ca.length; i++) {
            nextStack.push(ca[i]);
          }
        } else {
          const n = parseInt(idx, 10);
          if (!isNaN(n) && n < ca.length) {
            nextStack.push(ca[n]);
          }
        }
      } else if (typeof cur === 'object' && cur !== null) {
        const rec = cur as Record<string, Object>;
        const keys = Object.keys(rec);
        if (keys.includes(idx)) {
          nextStack.push(rec[idx]);
        }
      }
    }
    stack = nextStack;
  }
  for (const s of stack) {
    out.push(s);
  }
}

/** JSONPath 子集解析：支持 $.a.b / [*] / [n] / ..key / || 外的组合在调用层处理 */
function jsonPick(source: Object | null, rule: string): Object[] {
  if (source === null || source === undefined) {
    return [];
  }
  let r = rule.trim();
  if (r.startsWith('@json:')) {
    r = r.slice(6);
  }
  if (r.startsWith('$')) {
    r = r.slice(1);
  }
  if (r === '' || r === '*') {
    return [source];
  }
  // 解析段序列
  const segs: string[] = [];
  let i = 0;
  let first = true;
  while (i < r.length) {
    let deep = false;
    if (r[i] === '.') {
      if (r[i + 1] === '.') {
        deep = true;
        i += 2;
      } else {
        i += 1;
      }
    } else if (!first) {
      break;
    }
    first = false;
    let k = '';
    while (i < r.length && r[i] !== '.') {
      if (r[i] === '[') {
        const e = r.indexOf(']', i);
        if (e < 0) {
          k += r.slice(i);
          i = r.length;
          break;
        }
        k += r.slice(i, e + 1);
        i = e + 1;
        continue;
      }
      k += r[i];
      i++;
    }
    if (k.length > 0) {
      segs.push((deep ? '..' : '.') + k);
    }
  }
  if (segs.length === 0) {
    return [];
  }
  let cur: Object[] = [source];
  for (const seg of segs) {
    const out: Object[] = [];
    if (seg.startsWith('..')) {
      const keyName = seg.slice(2).replace(/\[[^\]]*\]/g, '');
      for (const obj of cur) {
        jsonFindByKey(obj, keyName, out, true);
      }
    } else {
      const path = seg.slice(1);
      for (const obj of cur) {
        jsonNavigate(obj, path, out);
      }
    }
    cur = out;
    if (cur.length === 0) {
      break;
    }
  }
  return cur;
}

/** 把 JSON 值转为字符串 */
function jsonToStr(v: Object | null): string {
  if (v === null || v === undefined) {
    return '';
  }
  if (typeof v === 'string') {
    return v as string;
  }
  if (typeof v === 'number' || typeof v === 'boolean') {
    return `${v}`;
  }
  return JSON.stringify(v);
}

/** 应用 ## 后的剔除规则：pattern###替换 */
function applyFilter(text: string, filter?: string): string {
  if (!filter || filter.length === 0) {
    return text;
  }
  try {
    const segs = filter.split('###');
    if (segs.length === 0) {
      return text;
    }
    const pattern = segs[0].replace(/^\/+|\/+$/g, '');
    const repl = segs.length > 1 ? segs[1] : '';
    if (!pattern) {
      return text;
    }
    return text.replace(new RegExp(pattern, 'g'), repl);
  } catch (e) {
    return text;
  }
}

/**
 * 从内容源提取列表集合（书列表/章节列表）
 */
export function pickList(htmlRoot: HtmlNode | null, json: Object | null, rule: string): Object[] {
  const r = (rule ?? '').trim();
  if (isJsRule(r)) {
    return [];
  }
  const branches = r.split('||');
  for (const br0 of branches) {
    let br = br0.trim();
    const hh = br.indexOf('##');
    if (hh > 0) {
      br = br.slice(0, hh);
    }
    // && 过滤语义简化为取第一段
    const am = br.indexOf('&&');
    if (am > 0) {
      br = br.slice(0, am);
    }
    // JSON 优先（有 JSON 数据且规则像 JSONPath）
    if (json !== null && json !== undefined && (br.startsWith('$') || br.startsWith('@json:') ||
      br.startsWith('..') || /^[a-zA-Z_]/.test(br))) {
      const raw = jsonPick(json, br);
      const out: Object[] = [];
      for (const o of raw) {
        if (Array.isArray(o)) {
          const arr = o as Object[];
          for (let i = 0; i < arr.length; i++) {
            out.push(arr[i]);
          }
        } else {
          out.push(o);
        }
      }
      if (out.length > 0) {
        return out;
      }
    }
    if (htmlRoot) {
      const segs = splitAtRule(br).filter((s: string) => s.length > 0);
      if (segs.length === 0) {
        continue;
      }
      let cands: HtmlNode[] = [htmlRoot];
      for (let k = 0; k < segs.length; k++) {
        const seg = segs[k];
        if (seg === 'text' || seg.startsWith('text.')) {
          break;
        }
        cands = applyHtmlSeg(cands, seg);
        if (cands.length === 0) {
          break;
        }
      }
      if (cands.length > 0) {
        const out: Object[] = [];
        for (const c of cands) {
          out.push(c);
        }
        return out;
      }
    }
  }
  return [];
}

/**
 * 从列表元素提取字符串（书名/作者/URL 等）
 * item 为 HtmlNode 走 HTML 规则；否则走 JSON 规则
 */
export function pickStr(item: Object | null, rule: string): string {
  const r = (rule ?? '').trim();
  if (isJsRule(r)) {
    return '';
  }
  if (r.length === 0) {
    if (item instanceof HtmlNode) {
      return item.innerText().trim();
    }
    return jsonToStr(item).trim();
  }
  const branches = r.split('||');
  for (const branch of branches) {
    let br = branch.trim();
    let filter = '';
    const hh = br.indexOf('##');
    if (hh >= 0) {
      filter = br.slice(hh + 2);
      br = br.slice(0, hh);
    }
    let val = '';
    if (item instanceof HtmlNode) {
      const segs = splitAtRule(br).filter((s: string) => s.length > 0);
      let cands: HtmlNode[] = [item];
      let done = false;
      for (let k = 0; k < segs.length; k++) {
        const seg = segs[k];
        if (seg === 'text' || seg.startsWith('text.')) {
          val = cands.map((c: HtmlNode): string => c.innerText()).join('\n');
          done = true;
          break;
        }
        // 终点属性：href/src/title/content 等
        const isLast = k === segs.length - 1;
        if (isLast && /^[a-zA-Z][-\w]*$/.test(seg) && !seg.startsWith('class.') && !seg.startsWith('tag.') &&
          !seg.startsWith('id.') && seg !== 'children') {
          const attrVals = cands.map((c: HtmlNode): string => c.attr(seg)).filter((s: string) => s.length > 0);
          if (attrVals.length > 0) {
            val = attrVals[0];
            done = true;
            break;
          }
        }
        cands = applyHtmlSeg(cands, seg);
        if (cands.length === 0) {
          break;
        }
      }
      if (!done && !val && cands.length > 0) {
        val = cands.map((c: HtmlNode): string => c.innerText()).join('\n');
      }
    } else {
      if (br.startsWith('@js:') || br.startsWith('<js>')) {
        continue;
      }
      const objs = jsonPick(item, br);
      if (objs.length > 0) {
        const parts: string[] = [];
        for (const o of objs) {
          parts.push(jsonToStr(o));
        }
        val = parts.join(' ');
      }
    }
    val = val.trim();
    if (val.length > 0) {
      return applyFilter(val, filter);
    }
  }
  return '';
}

/** 相对链接转绝对 */
export function resolveUrl(baseUrl: string, u: string): string {
  if (!u) {
    return '';
  }
  const link = u.trim();
  if (link.startsWith('http://') || link.startsWith('https://')) {
    return link;
  }
  if (link.startsWith('//')) {
    return 'https:' + link;
  }
  const bm = /^(https?:\/\/[^/]+)\//.exec(baseUrl);
  const origin = bm ? bm[1] : baseUrl;
  if (link.startsWith('/')) {
    return origin + link;
  }
  const cut = baseUrl.lastIndexOf('/');
  const dir = cut > 8 ? baseUrl.slice(0, cut) : baseUrl;
  return dir + '/' + link;
}

/** 从整页内容创建解析源 */
export class AnalyzeSource {
  htmlRoot: HtmlNode | null = null;
  json: Object | null = null;
  content: string = '';
  baseUrl: string = '';

  constructor(content: string, baseUrl: string) {
    this.content = content;
    this.baseUrl = baseUrl;
    if (looksLikeJson(content)) {
      try {
        this.json = JSON.parse(content) as Object;
      } catch (e) {
        this.json = null;
      }
    }
    if (this.json === null) {
      this.htmlRoot = parseHtml(content);
    }
  }

  list(rule: string): Object[] {
    return pickList(this.htmlRoot, this.json, rule);
  }

  /** item 为 null 时从文档根（HTML）或 JSON 根提取 */
  str(item: Object | null, rule: string): string {
    if (item === null || item === undefined) {
      if (this.htmlRoot) {
        return pickStr(this.htmlRoot, rule);
      }
      return pickStr(this.json, rule);
    }
    return pickStr(item, rule);
  }
}
