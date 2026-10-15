import { SearchRule } from '../../database/entities/rule';
import { SearchBook } from '../../database/entities/SearchBook';
import { BookSource } from '../../database/entities/BookSource';
import { AnalyzeSource, isJsRule, resolveUrl } from '../utils/AnalyzeEngine';
import requestUtil from '../utils/requestUtils';


export interface IXmlAnalysis {
  baseUrl: string  //搜索地址
  body: string  //请求内容（已抓取时传入，为空则本引擎自行抓取）
  bookSource: BookSource //书源
  variable?: string
  searchUrl: string
}

export class XmlAnalysisData {
  baseUrl: string = ''  //搜索地址
  body: string = '' //请求内容
  bookSource?: BookSource //书源
  variable?: string
  searchUrl: string = ''

  constructor(xmlDate?: IXmlAnalysis) {
    this.baseUrl = xmlDate?.baseUrl || ''
    this.body = xmlDate?.body || ''
    this.bookSource = xmlDate?.bookSource
    this.variable = xmlDate?.variable
    this.searchUrl = xmlDate?.searchUrl || ''
  }
}

export class XmlAnalysis {
  xmlDate: XmlAnalysisData = new XmlAnalysisData()
  url: string = ''
  source?: SearchRule
  searchUrl: string = ''

  init(xmlDate: XmlAnalysisData) {
    this.xmlDate = xmlDate
    this.url = xmlDate.searchUrl
    this.source = this.xmlDate.bookSource?.ruleSearch
    this.searchUrl = this.xmlDate.searchUrl
  }

  /**
   * 本地抓取 + 本地解析搜索结果（替代原远程 LegadoServer 的 /search/analysisBook）
   */
  async getBookList(): Promise<SearchBook[]> {
    let bookList: SearchBook[] = []
    if (!this.source || !this.source.bookList) {
      return bookList
    }
    if (isJsRule(this.source.bookList) || isJsRule(this.searchUrl)) {
      console.warn('该规则依赖 JS 引擎，本地解析暂不支持：' + (this.xmlDate.bookSource?.bookSourceName ?? ''))
      return bookList
    }
    // 1. 抓取页面内容
    let content = this.xmlDate.body
    if (!content) {
      try {
        content = await requestUtil.requestUrlHtml(this.searchUrl)
      } catch (e) {
        console.error('本地搜索抓取失败：' + JSON.stringify(e))
        return bookList
      }
    }
    // 2. 校验关键词（人机验证拦截检测）
    const checkKeyWord = this.source.checkKeyWord
    if (checkKeyWord && checkKeyWord.length > 0 && !content.includes(checkKeyWord)) {
      console.warn('checkKeyWord 未命中，源可能被验证拦截：' + this.searchUrl)
    }
    // 3. 本地解析
    const src = new AnalyzeSource(content, this.baseUrl())
    const items = src.list(this.source.bookList)
    const base = this.baseUrl()
    for (const it of items) {
      const book = new SearchBook()
      book.name = src.str(it, this.source.name ?? '')
      book.author = src.str(it, this.source.author ?? '')
      book.intro = src.str(it, this.source.intro ?? '')
      book.kind = src.str(it, this.source.kind ?? '')
      book.wordCount = src.str(it, this.source.wordCount ?? '')
      book.latestChapterTitle = src.str(it, this.source.lastChapter ?? '')
      const bookUrlRaw = src.str(it, this.source.bookUrl ?? '')
      if (bookUrlRaw) {
        book.bookUrl = resolveUrl(base, bookUrlRaw)
        book.tocUrl = book.bookUrl
      }
      const coverRaw = src.str(it, this.source.coverUrl ?? '')
      if (coverRaw) {
        book.coverUrl = resolveUrl(base, coverRaw)
      }
      if (book.name && book.bookUrl) {
        book.origin = this.xmlDate.bookSource?.bookSourceUrl ?? ''
        book.originName = this.xmlDate.bookSource?.bookSourceName ?? ''
        book.bookType = this.xmlDate.bookSource?.bookSourceType ?? 0
        book.source = this.xmlDate.bookSource
        bookList.push(book)
      }
    }
    return bookList
  }

  private baseUrl(): string {
    return this.xmlDate.baseUrl || this.searchUrl
  }

  //解析（入口保持原名，便于最小改动调用方）
  async analysisXml(): Promise<SearchBook[]> {
    return await this.getBookList();
  }

}
