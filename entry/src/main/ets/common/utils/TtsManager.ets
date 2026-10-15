/**
 * TtsManager —— 基于 HarmonyOS CoreSpeechKit 的离线语音合成朗读管理器
 * 用途：阅读器"朗读"功能。将章节文本切分为适合播报的片段，逐段合成播放，
 * 全部播完后通过 onChapterEnd 回调通知调用方（可用于自动朗读下一章）。
 */
import { textToSpeech } from '@kit.CoreSpeechKit';
import { BusinessError } from '@kit.BasicServicesKit';

const MAX_SEGMENT_LENGTH = 500;

export class TtsManager {
  private static instance: TtsManager | null = null;
  private engine: textToSpeech.TextToSpeechEngine | null = null;
  private creating: boolean = false;
  private segments: string[] = [];
  private segIndex: number = 0;
  private speaking: boolean = false;
  private seq: number = 0;
  // 章节自然播放完毕回调（用户手动停止不会触发）
  onChapterEnd: () => void = () => {
  };
  // 播放状态变化回调
  onStateChange: (playing: boolean) => void = () => {
  };
  // 朗读进度回调：本次会话累计已朗读（含正在朗读）的字符数
  onProgress: (spokenChars: number) => void = () => {
  };
  private spokenChars: number = 0;

  static getInstance(): TtsManager {
    if (!TtsManager.instance) {
      TtsManager.instance = new TtsManager();
    }
    return TtsManager.instance;
  }

  isSpeaking(): boolean {
    return this.speaking;
  }

  private async ensureEngine(): Promise<textToSpeech.TextToSpeechEngine> {
    if (this.engine) {
      return this.engine;
    }
    const extra: Record<string, Object> = {
      'style': 'interaction-broadcast',
      'locate': 'CN',
      'isBackStage': false
    };
    // 13 = 凌萧山（女声，推荐）；不可用时回退 0
    let engine: textToSpeech.TextToSpeechEngine;
    try {
      const params: textToSpeech.CreateEngineParams = {
        language: 'zh-CN', person: 13, online: 1, extraParams: extra
      };
      engine = await textToSpeech.createEngine(params);
    } catch (e) {
      const fallback: textToSpeech.CreateEngineParams = {
        language: 'zh-CN', person: 0, online: 1, extraParams: extra
      };
      engine = await textToSpeech.createEngine(fallback);
    }
    const listener: textToSpeech.SpeakListener = {
      onStart: (requestId: string, response: textToSpeech.StartResponse): void => {
      },
      onComplete: (requestId: string, response: textToSpeech.CompleteResponse): void => {
        // 仅在当前会话仍在播放时推进下一段
        if (this.speaking) {
          this.playNext();
        }
      },
      onStop: (requestId: string, response: textToSpeech.StopResponse): void => {
      },
      onError: (requestId: string, errorCode: number, errorMessage: string): void => {
        console.error(`TtsManager onError ${errorCode} ${errorMessage}`);
        this.stop();
      }
    };
    engine.setListener(listener);
    this.engine = engine;
    return engine;
  }

  /**
   * 将整章文本切分为播报片段：优先按段落，超长段落按标点与长度二次切分
   */
  private splitText(text: string): string[] {
    const paras = text.split(/\n+/).map(o => o.trim()).filter(o => o.length > 0);
    const segments: string[] = [];
    let buf = '';
    for (const para of paras) {
      if (para.length > MAX_SEGMENT_LENGTH) {
        if (buf.length > 0) {
          segments.push(buf);
          buf = '';
        }
        let piece = '';
        for (const ch of para) {
          piece += ch;
          if (piece.length >= MAX_SEGMENT_LENGTH || /[。！？!?；;\n]/.test(ch)) {
            segments.push(piece.trim());
            piece = '';
          }
        }
        if (piece.trim().length > 0) {
          segments.push(piece.trim());
        }
        continue;
      }
      if ((buf + para).length > MAX_SEGMENT_LENGTH) {
        segments.push(buf.trim());
        buf = para + '\n';
      } else {
        buf += para + '\n';
      }
    }
    if (buf.trim().length > 0) {
      segments.push(buf.trim());
    }
    return segments;
  }

  /**
   * 开始朗读一段完整文本（如整章）。会中断上一次未完成的朗读。
   * @returns 是否成功启动
   */
  async speak(text: string): Promise<boolean> {
    const segments = this.splitText(text);
    if (segments.length === 0) {
      return false;
    }
    this.speaking = false; // 先终止旧会话，避免旧 onComplete 推进新会话
    let engine: textToSpeech.TextToSpeechEngine;
    try {
      engine = await this.ensureEngine();
    } catch (e) {
      const err = e as BusinessError;
      console.error(`TtsManager createEngine failed: ${err?.code} ${err?.message}`);
      return false;
    }
    try {
      engine.stop();
    } catch (e) {
      // 未播放时 stop 可能抛错，忽略
    }
    this.segments = segments;
    this.segIndex = 0;
    this.spokenChars = 0;
    this.speaking = true;
    this.onStateChange(true);
    this.playNext();
    return true;
  }

  private playNext() {
    if (!this.speaking) {
      return;
    }
    if (this.segIndex >= this.segments.length) {
      this.speaking = false;
      this.onStateChange(false);
      this.onChapterEnd();
      return;
    }
    const engine = this.engine;
    if (!engine) {
      this.stop();
      return;
    }
    const text = this.segments[this.segIndex];
    this.segIndex++;
    // 上报进度：本段开始前的累计已读字符数
    this.onProgress(this.spokenChars);
    this.spokenChars += text.length;
    const speakParams: textToSpeech.SpeakParams = {
      requestId: `legado${Date.now()}_${this.seq++}`
    };
    try {
      engine.speak(text, speakParams);
    } catch (e) {
      const err = e as BusinessError;
      console.error(`TtsManager speak failed: ${err?.code} ${err?.message}`);
      this.stop();
    }
  }

  /**
   * 停止朗读（不触发 onChapterEnd）
   */
  stop() {
    this.speaking = false;
    this.segments = [];
    this.segIndex = 0;
    const engine = this.engine;
    if (engine) {
      try {
        engine.stop();
      } catch (e) {
        console.error('TtsManager stop error ' + JSON.stringify(e));
      }
    }
    this.onStateChange(false);
  }
}

export default TtsManager;
