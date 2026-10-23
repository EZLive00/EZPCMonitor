export interface HostInfo {
  name: string;
  os: string;
  kernel: string;
  arch: string;
  appVersion: string;
}

export interface CpuInfo {
  usage: number;
  perCore: number[];
  brand: string;
  cores: number;
  physical: number;
  freqMhz: number;
}

export interface MemInfo {
  total: number;
  used: number;
  available: number;
  swapTotal: number;
  swapUsed: number;
}

export interface DiskInfo {
  name: string;
  mount: string;
  fs: string;
  kind: string;
  total: number;
  free: number;
  used: number;
  readBps: number;
  writeBps: number;
  removable: boolean;
}

export interface NetInfo {
  rxBps: number;
  txBps: number;
  totalRx: number;
  totalTx: number;
}

export interface TempInfo {
  label: string;
  value: number;
  max: number | null;
  critical: number | null;
  primary: boolean;
}

export interface GpuInfo {
  name: string;
  utilization: number | null;
  memUsed: number | null;
  memTotal: number | null;
}

export interface ProcInfo {
  pid: number;
  name: string;
  cpu: number;
  mem: number;
}

export interface Snapshot {
  ts: number;
  host: HostInfo;
  cpu: CpuInfo;
  mem: MemInfo;
  disks: DiskInfo[];
  diskTotalReadBps: number;
  diskTotalWriteBps: number;
  net: NetInfo;
  temps: TempInfo[];
  gpu: GpuInfo | null;
  load: number[];
  uptime: number;
  procs: ProcInfo[];
}

export interface HistoryPoint {
  ts: number;
  cpu: number;
  mem: number;
  temp: number;
  rx: number;
  tx: number;
  disk: number;
  /** 磁盘读/写分开记，主面板要画双线 */
  diskRead?: number;
  diskWrite?: number;
  /** GPU 利用率，5s 一采，没有 GPU 数据的平台恒为 0 */
  gpu?: number;
}

export type WidgetMode = "card" | "bar";

/** 硬盘健康（SMART）。拿不到的字段一律 null，前端要如实显示「--」而不是编数字 */
export interface SmartAttr {
  name: string;
  value: string;
  extra: string;
  critical: boolean;
}

export interface DiskHealth {
  mount: string;
  device: string;
  model: string;
  serial: string;
  firmware: string;
  status: "good" | "warning" | "bad" | "unknown";
  smartStatus: string;
  lifeLeft: number | null;
  lifeUsed: number | null;
  spare: number | null;
  temperature: number | null;
  powerOnHours: number | null;
  powerCycles: number | null;
  writtenBytes: number | null;
  readBytes: number | null;
  mediaErrors: number | null;
  unsafeShutdowns: number | null;
  solidState: boolean | null;
  bus: string;
  attrs: SmartAttr[];
  source: string;
  note: string | null;
}

/** 顺序读写测速结果 */
export interface BenchResult {
  sizeMb: number;
  writeMbps: number;
  readMbps: number;
  writeMs: number;
  readMs: number;
  path: string;
  note: string | null;
}

/** 与 Rust 的 settings::Settings 一一对应 */
export interface AppSettings {
  intervalMs: number;
  historyEnabled: boolean;
  /** 保留时长（秒） */
  historyRetentionSecs: number;
  /** `auto` 或 zh-CN / zh-TW / en / ja / ko / fr / es */
  language: string;
  /** `auto` / `dark` / `light` */
  theme: string;
}

/** 落盘的历史点（10 秒一条，字段名对应 Rust 的 history::Point） */
export interface HistPoint {
  /** unix 秒 */
  t: number;
  cpu: number;
  mem: number;
  temp: number;
  rx: number;
  tx: number;
  disk: number;
  gpu: number;
}

/** 历史文件现状。bytesPerRecord 是拿真实文件反算的，用来估各档占用 */
export interface HistoryStats {
  enabled: boolean;
  retentionSecs: number;
  sampleSecs: number;
  minRetentionSecs: number;
  maxRetentionSecs: number;
  presets: number[];
  count: number;
  bytes: number;
  bytesPerRecord: number;
  oldest: number;
  newest: number;
  /** 程序榜那部分的采样节奏（秒） */
  procSampleSecs: number;
  /** 程序榜目录的实测占用 */
  procBytes: number;
  /** 空目录时每条采样占多少字节的经验值，用来估保留期占用 */
  procBytesPerSample: number;
}

/** 一个维度（CPU / 磁盘 IO）的历史统计 */
export interface DimStat {
  mean: number;
  peak: number;
  /** 峰值出现的 unix 秒 */
  peakTs: number;
  /** 活跃采样占比（0~100） */
  active: number;
}

/** 内存是存量不是流量，除了均值峰值还给首尾，用来算「这个窗口里涨了多少」 */
export interface MemStat {
  meanMb: number;
  peakMb: number;
  peakTs: number;
  firstMb: number;
  lastMb: number;
}

/** 历史榜里的一行：已按进程名合并 */
export interface ProcLeader {
  name: string;
  /** 它出现过几次采样（缺席 = 低于门槛） */
  samples: number;
  cpu: DimStat;
  mem: MemStat;
  io: DimStat;
}

export interface ProcLeaders {
  /** 窗口内的总采样次数（含空拍），所有均值和占比都以它为分母 */
  total: number;
  sampleSecs: number;
  rows: ProcLeader[];
}

