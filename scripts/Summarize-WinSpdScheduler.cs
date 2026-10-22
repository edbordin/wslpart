using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using Microsoft.Diagnostics.Tracing;
using Microsoft.Diagnostics.Tracing.Etlx;
using Microsoft.Diagnostics.Tracing.Parsers.Kernel;
using Microsoft.Diagnostics.Symbols;

// Run after capture, never alongside a benchmark: ETLX conversion and symbol
// lookup consume substantial CPU and memory. CPU samples include interrupt/DPC
// work above a callback on the stack; they are not exclusive miniport CPU time.
class SchedulerSummary
{
    class Tot
    {
        public long Count;
        public double Ms;
        public double MaxMs;
        public List<double> Values = new List<double>();
        public void Add(double n)
        {
            Count++;
            Ms += n;
            MaxMs = Math.Max(MaxMs, n);
            Values.Add(n);
        }
        public object Report()
        {
            Values.Sort();
            return new { count = Count,  total_ms = Ms,   mean_us = Count == 0 ? 0 : Ms * 1000 / Count,
                         p50_us = Q(.5), p99_us = Q(.99), max_us = MaxMs * 1000 };
        }
        double Q(double p)
        {
            return Values.Count == 0 ? 0 : Values[Math.Min(Values.Count - 1, (int)(p * Values.Count))] * 1000;
        }
    }
    class Susp
    {
        public double At;
        public string Stage;
        public bool WasReady;
    }
    static Dictionary<string, long> samples = new Dictionary<string, long>(), leaves = new Dictionary<string, long>(),
                                    cpus = new Dictionary<string, long>(), threads = new Dictionary<string, long>(),
                                    stacks = new Dictionary<string, long>();
    static Dictionary<string, Tot> off = new Dictionary<string, Tot>(), ready = new Dictionary<string, Tot>(),
                                   dpcs = new Dictionary<string, Tot>();
    static Dictionary<int, Susp> suspended = new Dictionary<int, Susp>();
    static Dictionary<int, double> readyAt = new Dictionary<int, double>();
    static void Inc(Dictionary<string, long> d, string k)
    {
        long n;
        d.TryGetValue(k, out n);
        d[k] = n + 1;
    }
    static void Add(Dictionary<string, Tot> d, string k, double v)
    {
        Tot t;
        if (!d.TryGetValue(k, out t))
            d[k] = t = new Tot();
        t.Add(v);
    }
    static Dictionary<int, string> stageCache = new Dictionary<int, string>();
    static string Stage(TraceCallStack s)
    {
        if (s == null)
            return "other";
        string cached;
        int key = (int)s.CallStackIndex;
        if (stageCache.TryGetValue(key, out cached))
            return cached;
        string stage = FindStage(s);
        stageCache[key] = stage;
        return stage;
    }
    static string FindStage(TraceCallStack s)
    {
        for (var f = s; f != null; f = f.Caller)
        {
            var n = f.CodeAddress.FullMethodName ?? "";
            if (n.Contains("SpdStorageUnitRingCompletionWorker") || n.Contains("SpdRingCompleteBatch"))
                return "completion";
            if (n.Contains("SpdStorageUnitRingPreparationWorker") || n.Contains("SpdRingPrepareBatch"))
                return "preparation";
            if (n.Contains("SpdStorageUnitRingProducerWorker"))
                return "producer";
            if (n.Contains("SpdStorageUnitRingKick"))
                return "kick";
        }
        return "other";
    }
    static string StackText(TraceCallStack s)
    {
        var frames = new List<string>();
        for (var f = s; f != null && frames.Count < 28; f = f.Caller)
            frames.Add(Frame(f));
        return string.Join(" <- ", frames);
    }
    static string Frame(TraceCallStack s)
    {
        return s == null ? "[no stack]"
                         : s.CodeAddress.ModuleName + "!" +
                               (string.IsNullOrEmpty(s.CodeAddress.FullMethodName)
                                    ? ("0x" + s.CodeAddress.Address.ToString("x"))
                                    : s.CodeAddress.FullMethodName);
    }
    static object Totals(Dictionary<string, Tot> d)
    {
        return d.ToDictionary(p => p.Key, p => p.Value.Report());
    }
    static int Main(string[] args)
    {
        if (args.Length != 3)
        {
            Console.Error.WriteLine("Usage: SchedulerSummary.exe trace.etl summary.json symbol-path");
            return 2;
        }
        try
        {
            Run(args);
            return 0;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine(e);
            return 1;
        }
    }
    static void Run(string[] args)
    {
        System.Net.ServicePointManager.SecurityProtocol = System.Net.SecurityProtocolType.Tls12;
        var opt = new TraceLogOptions();
        opt.ConversionLog = Console.Error;
        using (var log = TraceLog.OpenOrConvert(args[0], opt))
        {
            Console.Error.WriteLine("Converted events=" + log.EventCount + " lost=" + log.EventsLost);
            using (var sr = new SymbolReader(Console.Error, args[2], null))
            {
                foreach (var mod in log.ModuleFiles)
                    if (new[] { "winspd-arm64", "storport", "ntoskrnl", "ntkrnlmp", "vmbus", "storvsc", "vhdmp" }
                            .Contains(Path.GetFileNameWithoutExtension(mod.FilePath).ToLowerInvariant()))
                    {
                        try
                        {
                            log.CodeAddresses.LookupSymbolsForModule(sr, mod);
                        }
                        catch (Exception e)
                        {
                            Console.Error.WriteLine("Symbols " + mod.FilePath + ": " + e.Message);
                        }
                    }
            }
            var modules = log.ModuleFiles.ToArray();
            long nSample = 0, nCS = 0, nDpc = 0, nReady = 0, stackSample = 0, winspdSample = 0;
            double first = double.MaxValue, last = 0;
            foreach (var ev in log.Events)
            {
                if (ev.TimeStampRelativeMSec < first)
                    first = ev.TimeStampRelativeMSec;
                last = Math.Max(last, ev.TimeStampRelativeMSec);
                var sample = ev as SampledProfileTraceData;
                if (sample != null)
                {
                    nSample++;
                    var stack = ev.CallStack();
                    if (stack != null)
                        stackSample++;
                    var stage = Stage(stack);
                    if (stage != "other")
                        winspdSample++;
                    Inc(samples, stage);
                    Inc(cpus, stage + "/cpu" + ev.ProcessorNumber);
                    Inc(threads, stage + "/" + ev.ProcessName + "/tid" + ev.ThreadID);
                    Inc(leaves, stage + "/" + Frame(stack));
                    if (stage != "other")
                        Inc(stacks, stage + "/" + StackText(stack));
                    continue;
                }
                var cs = ev as CSwitchTraceData;
                if (cs != null)
                {
                    nCS++;
                    double t = ev.TimeStampRelativeMSec;
                    Susp p;
                    if (suspended.TryGetValue(cs.NewThreadID, out p))
                    {
                        Add(off, p.Stage, t - p.At);
                        double r;
                        if (readyAt.TryGetValue(cs.NewThreadID, out r))
                            Add(ready, p.Stage, Math.Max(0, t - r));
                        else if (p.WasReady)
                            Add(ready, p.Stage, t - p.At);
                        suspended.Remove(cs.NewThreadID);
                    }
                    readyAt.Remove(cs.NewThreadID);
                    // CallStack() on CSwitch describes the incoming thread.
                    // BlockingStack() identifies the outgoing callback owner.
                    var blocking = cs.BlockingStack();
                    var stage = Stage((int)blocking < 0 ? null : log.CallStacks[blocking]);
                    if (stage != "other")
                        suspended[cs.OldThreadID] =
                            new Susp { At = t, Stage = stage, WasReady = cs.OldThreadState.ToString() == "Ready" };
                    continue;
                }
                var rt = ev as DispatcherReadyThreadTraceData;
                if (rt != null)
                {
                    nReady++;
                    if (suspended.ContainsKey(rt.AwakenedThreadID) && !readyAt.ContainsKey(rt.AwakenedThreadID))
                        readyAt[rt.AwakenedThreadID] = ev.TimeStampRelativeMSec;
                    continue;
                }
                var dp = ev as DPCTraceData;
                if (dp != null)
                {
                    nDpc++;
                    var mod = modules.FirstOrDefault(m => dp.Routine >= m.ImageBase && dp.Routine < m.ImageEnd);
                    string name = mod == null ? "unknown" : Path.GetFileName(mod.FilePath);
                    Add(dpcs, name + "/cpu" + ev.ProcessorNumber, dp.ElapsedTimeMSec);
                }
            }
            var report = new {
                etl = args[0],
                events = log.EventCount,
                events_lost = log.EventsLost,
                truncated = log.Truncated,
                processors = log.NumberOfProcessors,
                sample_interval_ms = log.SampleProfileInterval.TotalMilliseconds,
                trace_first_ms = first,
                trace_last_ms = last,
                sample_events = nSample,
                samples_with_stack = stackSample,
                winspd_stage_samples = winspdSample,
                context_switches = nCS,
                ready_events = nReady,
                dpc_events = nDpc,
                stage_samples = samples,
                stage_cpu_samples = cpus,
                stage_thread_samples = threads,
                stage_stacks = stacks.OrderByDescending(p => p.Value).Take(200).ToDictionary(p => p.Key, p => p.Value),
                leaf_samples = leaves.OrderByDescending(p => p.Value).Take(250).ToDictionary(p => p.Key, p => p.Value),
                callback_off_cpu = Totals(off),
                callback_ready_wait = Totals(ready),
                dpc = Totals(dpcs)
            };
            var json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
            File.WriteAllText(args[1], json.Serialize(report));
            if (log.EventsLost != 0 || log.Truncated)
                throw new InvalidDataException("Incomplete ETW capture: inspect events_lost/truncated before using it.");
        }
    }
}
