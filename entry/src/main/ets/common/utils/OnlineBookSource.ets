/**
 * OnlineBookSource —— 在线书源的目录/正文本地获取与解析
 * 依赖 AnalyzeEngine 与已导入书源的 ruleToc / ruleContent 规则。
 */
import { BookSource } from '../../database/entities/BookSource';
import { ExploreRule } from '../../database/entities/rule';
import { AnalyzeSource, isJsRule, resolveUrl, pickStr } from './AnalyzeEngine';
import { NetworkHttp } from './NetworkHttp';

export class OnlineChapter {
  title: string = '';
  url: string = '';
  index: number = 0;

  constructor(title: string, url: string, index: number) {
    this.title = title;
    this.url = url;
    this.index = index;
  }
}

/** 规范化书源 header（JSON 字符串）为对象 */
function parseHeader(bookSource: BookSource): Record<string, string> {
  const out: Record<string, string> = {};
  const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36';
  out['User-Agent'] = ua;
  const raw = bookSource.header;
  if (raw && raw.trim().length > 0) {
    try {
      // header 可能是单引号 JSON
      let jsonStr = raw.trim();
      if (!jsonStr.startsWith('{')) {
        jsonStr = `{${jsonStr}}`;
      }
      jsonStr = jsonStr.replace(/([{,]\s*)([a-zA-Z_][\w-]*)\s*:/g, '$1"$2":').replace(/'/g, '"');
      const obj = JSON.parse(jsonStr) as Record<string, string>;
      Object.keys(obj).forEach((k: string) => {
        out[k] = `${obj[k]}`;
      });
    } catch (e) {
      console.warn('书源 header 解析失败：' + raw);
    }
  }
  if (!out['User-Agent']) {
    out['User-Agent'] = ua;
  }
  return out;
}

async function fetchPage(url: string, bookSource: BookSource, charset: string = 'UTF-8'): Promise<string> {
  const headers = parseHeader(bookSource);
  return NetworkHttp.getHtml(url, headers, charset);
}

/** 按 header 字符串抓取（发现页组件层只有 URL 与 header） */
async function fetchPageWithHeader(url: string, headerStr: string,
  charset: string = 'UTF-8'): Promise<string> {
  const headers: Record<string, string> = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36'
  };
  if (headerStr) {
    try {
      const obj = JSON.parse(headerStr) as Record<string, string>;
      Object.keys(obj).forEach((k: string) => headers[k] = `${obj[k]}`);
    } catch (e) {
      console.warn('header 解析失败：' + headerStr);
    }
  }
  return NetworkHttp.getHtml(url, headers, charset);
}

/**
 * 获取章节目录
 * @param bookUrl 书籍详情页 URL（无 ruleToc 时先取 tocUrl）
 * @param tocUrl 明确的目录页 URL（可空）
 */
export async function getChapterList(bookSource: BookSource, bookUrl: string, tocUrl: string): Promise<OnlineChapter[]> {
  const ruleToc = bookSource.ruleToc;
  if (!ruleToc || !ruleToc.chapterList || isJsRule(ruleToc.chapterList)) {
    return [];
  }
  let toc = tocUrl;
  if (!toc) {
    // 从详情页取 tocUrl
    const detail = await fetchPage(bookUrl, bookSource);
    const src = new AnalyzeSource(detail, bookUrl);
    const rToc = src.str(null, bookSource.ruleBookInfo?.tocUrl ?? '');
    if (rToc) {
      toc = resolveUrl(bookUrl, rToc);
    } else {
      toc = bookUrl;
    }
  } else {
    toc = resolveUrl(bookUrl, toc);
  }
  const content = await fetchPage(toc, bookSource);
  const src = new AnalyzeSource(content, toc);
  const items = src.list(ruleToc.chapterList);
  const chapters: OnlineChapter[] = [];
  const nameRule = ruleToc.chapterName ?? 'text';
  const urlRule = ruleToc.chapterUrl ?? '';
  for (let i = 0; i < items.length; i++) {
    const it = items[i];
    const title = pickStr(it, nameRule).replace(/\s+/g, ' ').trim();
    let url = urlRule ? pickStr(it, urlRule) : pickStr(it, 'href');
    if (!title) {
      continue;
    }
    if (!url && title.length > 0) {
      // 无独立链接时记录空串，由正文阶段回退整页
      url = '';
    }
    if (url) {
      url = resolveUrl(toc, url);
    }
    chapters.push(new OnlineChapter(title, url, chapters.length));
  }
  return chapters;
}

/**
 * 获取章节正文（含 nextContentUrl 翻页拼接与 replaceRegex 净化）
 */
export async function getChapterContent(bookSource: BookSource, chapterUrl: string): Promise<string> {
  const ruleContent = bookSource.ruleContent;
  if (!ruleContent || !ruleContent.content || isJsRule(ruleContent.content)) {
    return '';
  }
  let url = chapterUrl;
  let merged = '';
  let pages = 0;
  const maxPages = 8; // 防盗章翻页保护上限
  while (url && pages < maxPages) {
    pages++;
    let content = '';
    try {
      content = await fetchPage(url, bookSource);
    } catch (e) {
      console.error('正文抓取失败：' + url);
      break;
    }
    const src = new AnalyzeSource(content, url);
    let text = src.str(null, ruleContent.content);
    // 标题兜底：部分源正文块里含标题，仅第一页拼接
    if (!text && ruleContent.title) {
      text = src.str(null, ruleContent.title);
    }
    if (!text) {
      break;
    }
    text = applyReplaceRegex(text, ruleContent.replaceRegex);
    merged += (merged.length > 0 ? '\n' : '') + text;
    const next = ruleContent.nextContentUrl ? src.str(null, ruleContent.nextContentUrl) : '';
    if (!next) {
      break;
    }
    url = resolveUrl(url, next);
  }
  return merged;
}

/** 应用正文替换规则：正则###替换 多条用 ; 或换行分隔 */
function applyReplaceRegex(text: string, replaceRegex?: string): string {
  if (!replaceRegex || text.length === 0) {
    return text;
  }
  let out = text;
  const rules = replaceRegex.split(/\n|;(?![^"]*")/);
  for (const rule of rules) {
    const r = rule.trim();
    if (!r) {
      continue;
    }
    const segs = r.split('###');
    if (segs.length < 2) {
      continue;
    }
    const pattern = segs[0].replace(/^\/+|\/+$/g, '');
    const repl = segs[1];
    try {
      out = out.replace(new RegExp(pattern, 'g'), repl);
    } catch (e) {
      console.warn('替换规则无效：' + r);
    }
  }
  return out;
}

/** 发现页/搜索结果卡片通用产物 */
export class ExploredBook {
  name: string = '';
  author: string = '';
  intro: string = '';
  kind: string = '';
  wordCount: string = '';
  lastChapter: string = '';
  bookUrl: string = '';
  coverUrl: string = '';
}

/**
 * 本地解析发现页列表（替代远程 /common/analysisRules）
 * @param url 发现列表页地址（含 {{page}} 已替换）
 */
export async function exploreBooks(rule: ExploreRule, url: string,
  pageSize: number, header?: string): Promise<ExploredBook[]> {
  if (!rule || !rule.bookList || isJsRule(rule.bookList)) {
    return [];
  }
  const content = await fetchPageWithHeader(url, header ?? '');
  const src = new AnalyzeSource(content, url);
  const items = src.list(rule.bookList).slice(0, pageSize > 0 ? pageSize : 100);
  const out: ExploredBook[] = [];
  for (const it of items) {
    const b = new ExploredBook();
    b.name = src.str(it, rule.name ?? '');
    if (!b.name) {
      continue;
    }
    b.author = src.str(it, rule.author ?? '');
    b.intro = src.str(it, rule.intro ?? '');
    b.kind = src.str(it, rule.kind ?? '');
    b.wordCount = src.str(it, rule.wordCount ?? '');
    b.lastChapter = src.str(it, rule.lastChapter ?? '');
    const rawUrl = src.str(it, rule.bookUrl ?? '');
    b.bookUrl = rawUrl ? resolveUrl(url, rawUrl) : '';
    const rawCover = src.str(it, rule.coverUrl ?? '');
    b.coverUrl = rawCover ? resolveUrl(url, rawCover) : '';
    out.push(b);
  }
  return out;
}

/** 详情页解析产物 */
export class BookDetail {
  name: string = '';
  author: string = '';
  intro: string = '';
  kind: string = '';
  wordCount: string = '';
  lastChapter: string = '';
  coverUrl: string = '';
  tocUrl: string = '';
}

/**
 * 本地解析书籍详情页（ruleBookInfo）
 */
export async function getBookDetail(bookSource: BookSource, bookUrl: string): Promise<BookDetail> {
  const d = new BookDetail();
  const rule = bookSource.ruleBookInfo;
  if (!rule) {
    return d;
  }
  const content = await fetchPage(bookUrl, bookSource);
  const src = new AnalyzeSource(content, bookUrl);
  d.name = src.str(null, rule.name ?? '');
  d.author = src.str(null, rule.author ?? '');
  d.intro = src.str(null, rule.intro ?? '');
  d.kind = src.str(null, rule.kind ?? '');
  d.wordCount = src.str(null, rule.wordCount ?? '');
  d.lastChapter = src.str(null, rule.lastChapter ?? '');
  const cover = src.str(null, rule.coverUrl ?? '');
  d.coverUrl = cover ? resolveUrl(bookUrl, cover) : '';
  const toc = src.str(null, rule.tocUrl ?? '');
  d.tocUrl = toc ? resolveUrl(bookUrl, toc) : bookUrl;
  return d;
}
