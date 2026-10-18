# AXI4-Stream 固定帧与有界变长帧仲裁器

多路输入共享一个输出，支持固定优先级与 True Round-Robin、帧锁定及合格源之间的无气泡尾拍交接。
单时钟；默认固定16拍、全部字节有效，按静态水位准入；可选有界变长完整帧准入与尾拍字节掩码。
目标器件为 XC7Z020-2CLG400I，参考时钟100MHz。没有板级集成或上板实测。

水位及库存分析属于已有技术；当前以可复现工程工件/技术报告定位，不主张新仲裁算法。

## 参数、接口与保证边界

| 参数 | 支持值 | 默认 |
| --- | --- | --- |
| PORTS | 2、4、8 | 4 |
| DATA_WIDTH | 32、64位 | 32 |
| FIFO_DEPTH | 16、64拍/路 | 64 |
| ADMISSION_LEVELS | 每路5位，1..16；lane0为[4:0] | 每路1 |
| PACKET_MODE | 0固定16拍；1有界变长完整帧准入 | 0 |
| MAX_FRAME_BEATS | 两种模式均须满足1..FIFO_DEPTH；仅变长模式用其限制帧长 | FIFO_DEPTH |
| KEEP_ENABLE | 0忽略输入KEEP；1启用受限TKEEP，仅限PACKET_MODE=1 | 0 |

`axis_stream_arbiter`使用aclk/aresetn；aresetn为同步低有效复位，至少跨一个上升沿。
原生`stream_arbiter`使用clk/rst同步高有效复位。复位清空缓存、授权和错误，未完成事务作废。
mode_rr仅复位采样：0固定优先级，1轮询。输入第i路数据为`[i*DATA_WIDTH +: DATA_WIDTH]`，
其tlast/tvalid/tready独立；输出tid为输入端口号。无输入TID、TDEST、TUSER、TSTRB。
输入/输出tkeep（原生core为s_keep/m_keep），每路宽DATA_WIDTH/8，lane0占最低位。
KEEP_ENABLE=0忽略输入KEEP且有效输出KEEP全1，不增加KEEP存储位；原有实例应使用命名连接，
可将输入KEEP接全1、忽略输出KEEP。保留固定模式行为，不承诺新增端口后的按位置实例兼容。
protocol_error为每路粘滞协议错误；fifo_level每路占`clog2(FIFO_DEPTH)+1`位。

只在VALID&&READY的沿传输。输出背压时DATA/KEEP/LAST/来源/VALID保持；源不能等待READY才提出VALID。
满FIFO即使同沿弹出也不接收，队首组合可见，同沿新写入不能用于该沿读空。
初始授权寄存；固定模式尾拍重授权用`q_next=q+push-pop`，其余时候水位不改变活动帧锁定。
固定模式错误LAST/帧长/背压稳定性只报错，不修复、不丢帧。

H=1兼容立即启动，H=16在合法16拍格式下提供完整帧准入。
G表示帧内至多G−1个连续未成交的READY机会，READY=0冻结计数；G=1/2/4/8对应H=1/9/13/15。
未知供数源用H=16，不能由平均速率推测G。详见[契约与边沿](docs/admission-contract.md)。
保证依赖源契约；违约源可能仍符合AXIS并永久阻塞竞争者，硬件不监测/恢复这种违约。
任意长下游背压没有周期等待上界，固定优先级允许饥饿。改变水位不节省FIFO RAM容量。

## 有界变长完整帧模式

`PACKET_MODE=1`支持1..MAX_FRAME_BEATS拍，TLAST标识结束；ADMISSION_LEVELS必须为默认全1。
每路只有合法完整帧参与新授权，未完成尾帧留在FIFO中；活动帧仍按原握手规则和TLAST完成。
输入尾拍与输出尾拍同沿发生时按更新后的完整帧状态交接，无需供数间隔G保证。
FIFO满时仍保留原反压规则，不因满而放行未完成帧。子模块`stream_fifo`的m_valid仍表示非空，
完整帧隔离依赖顶层调度器使用其frame_available，不能将该子模块直接当独立完整帧输出接口。

第MAX_FRAME_BEATS拍成交但没有TLAST时，protocol_error置位并停止该路后续接收直到复位。
此前的合法完整帧仍可排空，错误帧已经接受的部分保留；其他路仍可服务。
不足上限就永久停发的源不会触发超时，也不会以未完成帧锁住输出。一般背压稳定性违例仍仅报错。
这是明确格式条件下的行为，不提供任意故障恢复。RR按帧轮流，不保证不同长度源的字节带宽相同。
旧固定16拍水位公式与等待界不作为变长模式的保证。

KEEP_ENABLE=1时，非末拍KEEP必须全1；末拍必须为从最低字节开始的连续非零掩码，
例如32位尾拍允许0001、0011、0111、1111，64位尾拍允许1..8个低位字节有效。
不支持全零拍、稀疏掩码或字节重排。非法KEEP成交后按长度故障规则停止该路，坏尾拍不提交，
此前完整帧仍可排空。最大帧长按拍计算；背压保持违例本身仅报错，若随后成交的KEEP非法仍执行停路规则。
这些检查不能当作任意故障隔离。

```sh
python3 scripts/run.py packet --axis --depth 16 --max-frame-beats 16
python3 scripts/run.py packet --axis --width 64 --depth 16 --max-frame-beats 7 --keep
python3 scripts/build.py axis_stream_arbiter --depth 16 --packet-mode 1 --max-frame-beats 16 --keep-enable 1
```

变长仿真覆盖1..MAX全部帧长、MAX=1/7/13/16/31/64、D个单拍帧、同时入尾/出尾、
未完成后缀、背压、半帧复位、超长停路、旧帧排空与健康源服务。KEEP用例覆盖32/64位全部合法尾掩码、
全零/洞形/高位起始尾及非末拍部分KEEP、同沿旧尾输出/坏尾输入、保持违例和禁用时忽略输入KEEP。
同一主记分板按接口握手记录合法帧尾、逐有效字节核对顺序与数量，不复制DUT完整帧计数器。

## 源码与复现入口

`rtl/`是可综合核心、FIFO、协议监测及既有片内自测；`sim/`是主握手记分板、研究负载及公开参考包装；
`formal/`是有明确范围的性质；`scripts/`是复现入口。生成物统一在忽略的`build/`。

当前版本包含完整构建脚本；部分早期提交缺少相关脚本，请使用当前完整源码进行复现。
文中实验结果来自既有验证记录，原始日志与历史源码快照未随本源码仓库提供。
以下命令用于重新运行，结果须按配置、工具版本及输入hash核对，不将新运行与历史测量混记。

入口使用Python3，已验证版本为3.12.3。按所需任务安装工具，所有命令在仓库根目录执行：

| 任务 | 已用工具 | 配置方式 |
| --- | --- | --- |
| 核心仿真、同负载预实验 | Icarus12.0 devel g2693dd32b | `IVERILOG`、`VVP`分别指定可执行文件，或加入PATH |
| 综合与参考上下文实现 | Vivado2025.2 | `VIVADO`指定可执行文件，或将`vivado`/`vivado.bat`加入PATH |
| 形式化检查 | Yosys0.33、yosys-smtbmc、Z3 4.8.12 | Linux/WSL，将三项工具加入PATH，无需SBY |
| RFNoC仿真、实现、公共源综合 | Windows版Vivado2025.2及其XPM/unisim模型 | Windows/WSL，`VIVADO_ROOT`指定含`bin/vivado.bat`的安装目录 |

WSL调用Windows版Vivado时，PATH中还需有`cmd.exe`与`wslpath`。
`study.py`默认使用外部AXIS基线，`build.py axis_external`也需要该依赖；入口按清单下载或核验缓存。

核心仿真与库存模型检查：

```sh
python3 scripts/run.py all --events
python3 scripts/run.py admission --axis --depth 16 --admission 9 --gap 2
python3 scripts/run.py admission --axis --depth 16 --admission 8 --gap 2 --expect-starve
python3 scripts/check_admission.py
```

固定帧、有界变长帧与KEEP的完整回归记录：**162次仿真、13项非法参数拒绝全部通过，37份合法编译日志无警告**。
包括原136项固定模式回归、16项全字节变长帧及10项KEEP测试；所有新增配置均跑两种仲裁策略。
固定模式覆盖12种AXIS参数组合、FIFO/自测/负例、G=1/2/4/8、H*及H*−1、H16、异构水位、
同沿阈值跨越、尾拍背压、复位和违约恢复。完整矩阵结果不能推断所有参数组合均已布局布线。
记分板按实际输入/输出握手检查数据、顺序、不混帧及稳定性；契约违例与AXIS错误分别统计。
G2/4/8的H*−1在第16读机会出现预期断供，源仍满足契约，恢复后排空正确；H=0非法。

`stream_selftest`仍为默认4/32/64、H1，包含可综合负载、检查器和计数器。
run撤销后完成已呈现帧并排空；done还需结合零错误及输入/输出数量核对。它没有板级引脚封装。

## 同负载预实验与代价（历史结果）

固定模式历史版本的`study.py`在同一记分板中完成66组预实验：9场景，burst/random使用预登记种子1和20261027，
其余确定性场景各1次，共11组负载×6候选。B0=H1、B1=H16、B2=H8，C按各路契约配置水位。
六候选共用逐拍释放计划、载荷和下游ready；所有生成帧最终排空且逐拍校验通过。
运行`python3 scripts/study.py`可生成CSV、互斥周期分类、逐源/总吞吐、延迟均值/P99/最大值、
未完成样本及工具/源码/负载hash，输出位于`build/study/`。
P99是nearest-rank观察统计，未提供论文级区间估计，不能作为最坏等待证明。

| 孤立帧，源0均值/周期 | C首入→首出 / B1 | C生成→完成 / B1 / B0 |
| --- | --- | --- |
| G=2 | 18 / 32 | 33 / 47 / 31 |
| G=8 | 114 / 122 | 129 / 137 / 121 |

C比完整帧准入早启动，但上述完成延迟劣于立即启动。周期背压场景源0完成延迟均值C为38.5625，
B0为25.625，保留这一不利结果。活动断供减少会转成准入等待，不宣称所有流量端到端延迟都下降。
全部场景同窗口总吞吐相同，饱和均1拍/周期。饱和窗口末仍有260–261帧未完成，各候选分列并最终排空。
窗口完成延迟按完成沿入窗，首入到首出延迟按首出沿入窗；排空统计保留全部生成帧。

E_WORD/E_FRAME冻结verilog-axis提交`48ff7a7e2ef782cf778d47910cf85835c64b1bce`（MIT）。
`python3 scripts/fetch_axis.py`按SHA256获取4份RTL及COPYING，`--check`离线校验。
其额外流水使总容量为N*(D+2)+2；主配置74拍，本核心64拍，且接口诊断功能不同，故仅独立参考。
E在READY=1且无传输时只标`external_unclassified`，READY=0仍计下游未就绪；
其它细分项的0不表示无断供，不能作等容量策略胜负证据。

## RFNoC短记录最小对照

已有RFNoC实验保留真实radio事件FIFO、等待ACK、双向CDC及原terminal完整包门控，比较4→1汇聚的三种结构：
本工程完整帧核心、同M=6检查的帧FIFO+RR、仅按帧RR。核心RTL未改；来源固定24 B整字，不是实机流量采集。
仅RR候选的5份新增轨迹与此前两个帧缓存候选的12份已核验轨迹合并分析；三方合法业务均通过同一握手记分板及独立身份账本检查。
RFNoC对照扩展后的完整回归再次通过162项长期仿真、13项预期参数拒绝，37份合法编译日志无警告。
稀疏首拍接受至输出完成为120/140/70ns，核心综合为319/234、328/442、137/222 LUT/FF；
三方在同一100MHz参考上下文通过实现，候选自身存储槽为64/74/6，不称等容量算法对照。
该案例未观察到额外完整帧缓存的收益；结论限于上述业务、共同包门控及容量配置。

故障保护另列：原两个帧缓存候选在gate后失尾诊断中均需全路径干预，复位各作废130条记录（健康路97条）。
仅RR没有相同的末级拦截保证，不运行或混排该故障比较；这些结果不是全系统时序或上板实测。
可先准备参考脚本，再运行相位0的仿真、分析与三候选参考实现：

```sh
python3 scripts/rfnoc_compare.py prepare
python3 scripts/rfnoc_compare.py sim
python3 scripts/rfnoc_compare.py analyze
python3 scripts/rfnoc_compare.py impl
```

`prepare`只需Python和本仓库文件，无需Git、Vivado、外部源码缓存或网络。
其余入口会下载或核验外部源码；`analyze`使用已有仿真轨迹，不启动Vivado。
仅运行第三候选可加`--candidate rr_only`，分析所选候选前须先生成对应轨迹。
参考脚本直接取自本仓库，运行时记录文件SHA256，不要求Git历史；源码ZIP也可使用相同入口。
来源/版本、相位补测、ACK模型、过载交付交集及证据复用范围见[RFNoC比较说明](docs/rfnoc-comparison.md)。

## 形式化范围

工具与平台要求见前面的依赖表。若使用`build/tools/root/usr/`中的本地隔离安装，入口也会自动发现。

变长帧与KEEP的既有验证：2/32/16、MAX3、KEEP启用的两个预登记场景，24步BMC及各两个cover通过。
分别检查超长帧，以及旧合法尾输出同沿接受KEEP=0101坏尾；合法尾含部分字节，后段READY任意。
检查载荷/KEEP/LAST、帧隔离、背压保持、占用与停接，不能推广为任意流量或无界证明。
默认固定模式G2/H9原场景48步BMC与completion cover重新通过，H8断供反例按预期检出。

```sh
python3 scripts/formal.py --target packet --depth 24 --timeout 90
python3 scripts/formal.py --depth 48
python3 scripts/formal.py --ready arbitrary --check cover --depth 48
python3 scripts/formal.py --target scheduler --depth 12
```

`formal.py --depth`表示包含复位的检查步数；仿真和构建入口的同名参数表示FIFO深度。
上述packet检查固定使用2路、32位、FIFO深度16、最大帧长3，不随`--depth`改变硬件配置。

以下是固定模式历史版本证据：实际2/32/16核心、G2/H9、两源各一帧、固定前缀尾拍交接、持续READY的48步BMC及完成cover通过；
H8产生真实不断供断言反例。任意READY在同一固定前缀场景的完成/背压cover通过，**cover不是安全证明**。
不断供断言从首拍输出握手后开始；默认只查控制/LAST，不证明任意32位载荷或启动活性。
一般流量及任意READY的48步BMC曾超时，完整核心的无界证明未建立；没有把这些结果标为通过。
真实2路frame_arbiter的锁定保持、合格选择与非空候选授权通过12步BMC、时间归纳及cover；
该模块证明不覆盖父级准入计算、优先级顺序、RR等待界或整帧完成。
独立库存模型的8组穷尽检查是另一证据层级，不能替代上述RTL验证。

## 综合与参考上下文实现

Vivado2025.2，xc7z020clg400-2，100MHz，setup/hold不确定度0.1/0.05ns。
同钟BUFG/FDRE参考边界setup预算8/8/6ns，正常同沿hold；没有false-path、多周期或min-delay豁免。

固定帧及KEEP接口的三种AXIS配置已有通过记录，表中依次为路数/数据位宽/FIFO深度：

| 模式与配置 | WNS/WHS ns | 核心综合 LUT/FF | 实现总 LUT/FF | 参考FF |
| --- | --- | --- | --- | --- |
| 固定16拍，4/32/16，H1，KEEP关闭 | 2.055 / 0.065 | 277 / 215 | 273 / 422 | 207 |
| 完整帧+KEEP，4/32/16，MAX16 | 2.132 / 0.042 | 351 / 254 | 345 / 477 | 223 |
| 完整帧+KEEP，8/64/64，MAX64 | 0.537 / 0.044 | 1573 / 872 | 1568 / 1616 | 744 |

三者BRAM均0；setup/hold/pulse-width失败端点、覆盖问题、DRC及路由错误均0，路由完整。
这些结果来自当时保存的干净源码快照，输入hash及原始报告已记录，未随本源码仓库提供。
参考夹具只移除KEEP关闭时综合留下的无连接KEEP输入，连接有效的输入和正常时序路径照常检查。

```sh
python3 scripts/build.py axis_stream_arbiter --depth 16
python3 scripts/build.py axis_stream_arbiter --ports 8 --width 64 --depth 64 --packet-mode 1 --max-frame-beats 64 --keep-enable 1
```

以下命令可重跑固定模式对照配置；表格保留历史版本的测量结果：

```sh
python3 scripts/build.py axis_stream_arbiter --depth 16 --admission 1,9,13,16
python3 scripts/build.py axis_external --depth 16 --frame-fifo 0
python3 scripts/build.py axis_external --depth 16 --frame-fifo 1
```

B0/B1使用`--admission 1`/`16`；边界配置见下表，可用--ports/--width/--depth指定。
新运行的结果在`build/vivado/<top>/<configuration>/registered/`。
下表原始报告及输入hash来自历史源码快照归档，未随本源码仓库提供。

| 配置与水位 | WNS/WHS ns | 核心综合 LUT/FF | 实现总 LUT/FF | 参考FF |
| --- | --- | --- | --- | --- |
| B0 4/32/16，H1 | 2.191 / 0.057 | 277 / 214 | 273 / 417 | 203 |
| B1 4/32/16，H16 | 2.129 / 0.057 | 293 / 214 | 288 / 417 | 203 |
| C 4/32/16，1,9,13,16 | 2.524 / 0.061 | 278 / 214 | 275 / 417 | 203 |
| E_WORD 4/32/16 | 3.766 / 0.030 | 245 / 398 | 244 / 576 | 178 |
| E_FRAME 4/32/16 | 3.324 / 0.045 | 308 / 422 | 305 / 600 | 178 |
| C 2/32/16，9,16 | 3.542 / 0.048 | 152 / 108 | 151 / 228 | 120 |
| C 8/64/64，15,1,9,13,16,1,9,13 | 0.317 / 0.042 | 1363 / 728 | 1369 / 1400 | 672 |

以上7种配置是固定模式历史版本的实际综合/布局/布线结果，BRAM均0；setup/hold/pulse-width失败端点、覆盖问题、DRC错误、
路由错误均0，路由完整。核心综合与实现总资源是不同阶段，不能混为同一净表；不从WNS推最大频率。
参考边界不是业务封装；保留OOC外部时钟到BUFG未集成的Route35-198提示，不能代替真实父级/板级签核。
`--context ports`仅作裸端口诊断，不输出物理验收PASS。历史实现数字不作为当前版本证据。

## 已知限制与AI辅助说明

缺项仍是实际板卡型号、引脚、真实时钟/复位、PS7及统计读取接口；无板级bitstream、下载或上板结果。
未完成实际生产源的G保证/集成核验、完整RTL无界证明及论文级统计。

本项目在资料整理、RTL与验证脚本开发、实验分析和文档核对及翻译中使用了AI辅助工具。

## 许可

本仓库原创RTL、仿真与形式化验证代码、Python/Tcl脚本、配置及文档统一采用
**GNU GPLv3（仅此版本，SPDX：`GPL-3.0-only`）**，全文见[LICENSE](LICENSE)。
允许使用、研究、修改和商业分发；分发受GPL覆盖的版本时须遵守对应源码、许可及版权声明等要求。
版权与第三方范围见[NOTICE](NOTICE)。

外部verilog-axis保留MIT许可，所选UHD HDL保留LGPL-3.0-or-later及各文件声明；
Vivado及其XPM/unisim模型按厂商条款使用，不包含在本项目的许可授予中。
工程外论文、图表及数据按各自许可声明处理，本声明不替代文章出版协议。
