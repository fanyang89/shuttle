# 用 Shuttle 测试 Zig 并发代码

本目录提供 Zig 0.17.1 适配器：Zig 场景通过 C ABI 调用 Rust 版 Shuttle 引擎，
获得随机调度、固定种子与失败轨迹回放。已在本机 x86_64 Linux 验证。

## 一、对 stdgo 的验证结论

接入对象：https://github.com/fanyang89/stdgo （jiacai2050/stdgo 的 fork，
本地 `/home/fanmi/workspace/stdgo`，改动见下文"fork 改动"）。

### 发现 5 个可回放缺陷

以下均在种子 42、200 轮调度内首次发现，且用打印的编码轨迹重放得到相同失败。
`cd wrappers/zig` 后执行：

```sh
zig build test -Dstdgo=/home/fanmi/workspace/stdgo        # 全量
zig build stdgo-run -Dstdgo=/home/fanmi/workspace/stdgo -- singleflight            # 首次运行
zig build stdgo-run -Dstdgo=/home/fanmi/workspace/stdgo -- singleflight <编码轨迹>  # 回放
```

| # | 位置 | 现象（错误名 / 诊断） | 根因 | 回放轨迹 |
|---|------|----------------------|------|----------|
| 1 | `sync/singleflight.zig` `do` | `IncorrectShared` | 执行路径固定返回 `.shared = false`（约 143 行），从不读 `c.dups`。有重复调用者共享结果时，首个执行者本应返回 `shared = true`（Go 语义）。依赖该标志做独占判断的调用方会误判 | `91011c2a80aa80a0202a00` |
| 2 | `sync/semaphore.zig` `acquire` | `AcquiredAfterCancellation` | 快路径先授予权重（74–80 行），之后才检查 `ctx.done()`。Context 已取消时即使资源空闲也应返回 `Canceled`。取消后仍占用资源，推迟取消响应 | `9101092a000000` |
| 3 | `sync/errgroup.zig` `spawn` | `exceeded max_steps`（等待死循环） | `wg.add(1)` 先于 `allocator.create(TaskContext)` 执行；分配失败返回 OOM 时计数不回退（且限额路径的 `active_count` 也不回退）。随后 `wait()` 永久自旋 | `9101402a00000000000000000000000000000000` |
| 4 | `sync/singleflight.zig` `do` | `LockHeldAfterAllocationFailure` | 锁内 `try self.allocator.create(Call)`（86 行附近）失败直接返回，`self.mu` 未解锁。此后所有 `do`/`deinit` 永久阻塞 | `9101032a00` |
| 5 | `sync/errgroup.zig` `deinit` | `exceeded max_steps`（互相等待） | `deinit`/`wait` 持有组锁调用 `join`；worker 失败路径 `setError` 需要同一把锁 → 互相等待。未先 `wait` 就 `deinit`（如 `errdefer`）即触发 | `9101409bdbd29794bbb9eb920100aa2aa2aaaaaaaaaaaaaaaaaaaaaaaa` |

说明：#3/#5 的诊断是步数超限而非死锁报告，因为 stdgo 的锁是"让出 + 自旋"等待，
在 Shuttle 下不会转入阻塞状态，只能靠步数上限终止。互等结构本身见根因列。

### 通过项（未发现缺陷）

`basic`（`Once` 恰好执行一次 + `Mutex` 互斥 + `WaitGroup`）、`pool`（对象归还唯一性）、
`semaphore`（容量约束与许可归还）、`errgroup`（限额 + 首个错误传播）、
`clients`（`expvar.Float`、`time.rate`、`CookieJar`、`CancelContext` 取消可见性）、
`pipe`（内存管道半关闭与 EOF）、`db`（MockDriver 连接池开关计数一致）。
"未发现"仅指上述场景与调度轮数内，不构成正确性证明。

### 覆盖矩阵

| 组件 | 状态 |
|------|------|
| `sync`：Mutex / Once / WaitGroup / Semaphore / ErrGroup / SingleFlight / Pool | 已插桩（经 `src/sync/backend.zig`） |
| `context`（取消传播路径）、`time.rate`、`expvar`、`net.pipe`、`database/sql` 连接池、`http.CookieJar` | 部分插桩（同步走 stdgo Mutex，随调度） |
| 原生 `std.atomic.Value`（`context.canceled`、`DB.ref_count`、`expvar.Int`、multipart boundary） | 无调度点；顺序一致模型下不影响结果 |
| `std.Thread.spawn` 直用（`context` 定时器与 `AfterFunc`、`os/exec` 看门狗） | 未覆盖：真实 OS 线程，回调内不可触适配器原语 |
| `std.Io.RwLock`（`net/http/conn` CA 锁）、`std.Io.Event`/futex 等待、真实网络 | 未覆盖 |

## 二、适配器用法

### 运行与回放

```sh
cd wrappers/zig
zig build test                                   # 适配器自带场景
zig build test -Dstdgo=/path/to/stdgo            # 加测 stdgo 套件
zig build run -- lost-update                     # 自带"预期失败"演示
zig build run -- lost-update "$schedule"         # $schedule 取自标准错误的编码轨迹
zig build run -Dscenario=/path/to/my_scenario.zig
```

### 编写场景

```zig
const shuttle = @import("shuttle");

fn increment(n: *shuttle.AtomicU32) !void {
    _ = n.fetchAdd(1, .monotonic);
}

fn scenario() !void {
    var n = shuttle.AtomicU32.init(0);
    defer n.deinit();
    const t = shuttle.Thread.spawn(&n, increment);
    try increment(&n);
    t.join();
    if (n.load(.acquire) != 2) return error.LostUpdate;
}

pub fn main() void {
    shuttle.checkRandom(scenario, .{ .iterations = 100, .seed = 42 });
}
```

**状态与生命周期。** Shuttle 每轮重新调用场景函数：请在函数内创建状态和任务，
每个任务只 `join` 一次。任务参数是借用的，必须活到 `join` 返回；等所有使用者
结束后再释放锁和原子变量；只释放自己持有的锁。需要显式调度点时调用
`shuttle.yield()`。

**可观测范围。** 只有通过适配器的操作受调度：OS 线程、阻塞 I/O、Zig 原生原子
不会被接管。所有原子操作按顺序一致性建模，测试通过不能排除弱内存序缺陷。

**失败处理。** 每个场景在独立进程运行。要让失败可回放，请从回调返回 `error`：
回调返回后 Rust panic 钩子打印失败轨迹，`zig-test` 构建配置随即终止进程，
不跨 Zig 栈展开。Zig `@panic`/trap 会绕过钩子。自行调用 `shuttle.replay` 时
传入编码轨迹，并保持原场景的步数上限。

## 三、stdgo 集成原理（fork 改动）

fork 相对上游的全部改动（本地未提交）：

- 新增 `src/sync/backend.zig`：读取根模块可选声明 `stdgo_sync_backend`，
  不存在时回退 `std.atomic.Value` / `std.Thread`。生产构建零行为变化。
- `src/sync/` 下 mutex / once / waitgroup / semaphore / errgroup 六个文件把
  `std.atomic.Value` 与 `std.Thread.yield/spawn` 换成 `backend.Value` /
  `backend.Thread`（Once 的 `doWithState` 注入点已并入 `do`，生产与测试共用算法）。
- stdgo 自身测试无回归：323 通过、1 跳过（网络代理不可达，与本改动无关）。

测试侧：`wrappers/zig/stdgo_backend.zig` 提供注入后端——`Value` 在每个原子
操作前 `shuttle.yield()`、操作本体原生执行（顺序一致模型）；`Thread` 映射为
Shuttle 任务。`stdgo_sync.zig` 是场景入口，`stdgo_consumers.zig` 覆盖上层消费者。

**适配器边界（非 stdgo 缺陷）。** Shuttle 的所有任务运行在同一 OS 线程：
`context` 用 OS 线程 ID 判断通知重入（`context.zig` `unsubscribeImpl`），
真实线程下正确的等待保护在适配器下会被同 ID 短路。涉及该路径的场景
（通知回调中并发反订阅）不被建模。
