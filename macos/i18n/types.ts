/**
 * 从简体中文推出所有语言必须满足的形状。
 *
 * 这样七个字典是**编译期**对齐的：少一条键、多一条键、拼错一条键，`tsc` 都会报错，
 * 不需要靠人工比对，也不会出现运行到某个界面才看到空白的情况。
 */
export type Dict = typeof import("./zh-CN").strings;
export type Key = keyof Dict;

/**
 * 复数短语的键。
 *
 * 刻意在这里手写而不是从 zh-CN 反推：zh-CN 的 `plurals` 要用 `Plurals` 标注，
 * 从它反推就成了循环引用。
 */
export type PluralKey =
  | "p.sec"
  | "p.min"
  | "p.hour"
  | "p.day"
  | "p.records"
  | "p.points"
  | "p.sensors"
  | "p.attrs";

/** 每条复数短语固定两项：`[单数, 复数]`；无单复数的语言写两遍一样的 */
export type Plurals = Record<PluralKey, [string, string]>;

export type Vars = Record<string, string | number>;
