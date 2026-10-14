declare module '@novnc/novnc' {
  export default class RFB extends EventTarget {
    constructor(target: HTMLElement, url: string, options?: { credentials?: { password?: string }; shared?: boolean });
    scaleViewport: boolean;
    resizeSession: boolean;
    viewOnly: boolean;
    focusOnClick: boolean;
    disconnect(): void;
    focus(): void;
    blur(): void;
    sendKey(keysym: number, code?: string, down?: boolean): void;
  }
}
