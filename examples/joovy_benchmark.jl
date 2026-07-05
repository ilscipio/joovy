# Joovy Compilation Benchmark
#
# Open this file in the IDE, then call: run_benchmark()
# Runs each function twice — once with Joovy (lazy), once without (eager) —
# and prints a side-by-side comparison with speedup stats.

using Plots
using DataFrames
using Printf

function make_scatter(n)
    x = randn(n)
    y = randn(n)
    scatter(x, y, title="Random scatter", xlabel="x", ylabel="y")
end

function make_heatmap(n)
    data = randn(n, n)
    heatmap(data, title="Random heatmap")
end

function make_histogram(n)
    data = randn(n)
    histogram(data, bins=50, title="Normal distribution")
end

function make_dataframe(n)
    DataFrame(x=randn(n), y=randn(n), group=rand(["A","B","C"], n))
end

function make_surface(n)
    x = range(-3, 3, length=n)
    y = range(-3, 3, length=n)
    surface(x, y, (x, y) -> sin(x) * cos(y), title="Surface plot")
end

function make_contour(n)
    x = range(-2, 2, length=n)
    y = range(-2, 2, length=n)
    contour(x, y, (x, y) -> x^2 + y^2, title="Contour plot", fill=true)
end

function make_bar_chart(n)
    groups = ["A", "B", "C", "D", "E"]
    vals = rand(length(groups))
    bar(groups, vals, title="Bar chart", legend=false)
end

function make_line_plot(n)
    x = range(0, 4π, length=n)
    plot(x, [sin.(x) cos.(x) sin.(2x)], title="Trig functions", label=["sin" "cos" "sin2x"])
end

function full_report(n)
    df = make_dataframe(n)
    p1 = make_scatter(n)
    p2 = make_heatmap(min(n, 100))
    p3 = make_histogram(n)
    plot(p1, p2, p3, layout=(1, 3), size=(1200, 400))
end

function heavy_report(n)
    p1 = make_scatter(n)
    p2 = make_heatmap(min(n, 50))
    p3 = make_histogram(n)
    p4 = make_surface(50)
    p5 = make_contour(50)
    p6 = make_bar_chart(n)
    p7 = make_line_plot(n)
    plot(p1, p2, p3, p4, p5, p6, p7, layout=(2, 4), size=(1600, 800))
end

const BENCH_FUNCS = [
    ("make_scatter",   () -> make_scatter(100)),
    ("make_heatmap",   () -> make_heatmap(50)),
    ("make_histogram", () -> make_histogram(100)),
    ("make_dataframe", () -> make_dataframe(100)),
    ("make_surface",   () -> make_surface(50)),
    ("make_contour",   () -> make_contour(50)),
    ("make_bar_chart", () -> make_bar_chart(5)),
    ("make_line_plot",   () -> make_line_plot(100)),
    ("full_report",    () -> full_report(100)),
    ("heavy_report",   () -> heavy_report(100)),
]

function _run_pass(label)
    times = Float64[]
    println("  Running: $label")
    for (name, f) in BENCH_FUNCS
        t = @elapsed f()
        push!(times, t)
        @printf("    %-20s %8.3f s\n", name, t)
    end
    total = sum(times)
    @printf("    %-20s %8.3f s\n", "TOTAL", total)
    println()
    return times
end

function run_benchmark()
    joovy_on = isdefined(Main, :_joovy_session)

    println()
    println("=" ^ 70)
    println("  JOOVY COMPILATION BENCHMARK")
    println("  Joovy detected: $(joovy_on ? "YES" : "NO")")
    println("=" ^ 70)
    println()

    # --- Pass 1: first call (compile cost) ---
    println("─" ^ 70)
    println("  PASS 1 — First call (includes compilation)")
    println("─" ^ 70)
    times_1st = _run_pass("first call")

    # --- Pass 2: second call (already compiled) ---
    println("─" ^ 70)
    println("  PASS 2 — Second call (already compiled)")
    println("─" ^ 70)
    times_2nd = _run_pass("second call")

    # --- Summary table ---
    println("=" ^ 70)
    println("  SUMMARY")
    println("=" ^ 70)
    @printf("  %-20s %10s %10s %10s\n", "Function", "1st (s)", "2nd (s)", "Speedup")
    println("  " * "-" ^ 54)
    for (i, (name, _)) in enumerate(BENCH_FUNCS)
        t1 = times_1st[i]
        t2 = times_2nd[i]
        speedup = t1 / max(t2, 1e-9)
        @printf("  %-20s %10.3f %10.3f %9.1fx\n", name, t1, t2, speedup)
    end
    println("  " * "-" ^ 54)
    total_1st = sum(times_1st)
    total_2nd = sum(times_2nd)
    @printf("  %-20s %10.3f %10.3f %9.1fx\n", "TOTAL", total_1st, total_2nd, total_1st / max(total_2nd, 1e-9))
    println()
    println("  Mode: $(joovy_on ? "JOOVY (lazy tier-1 compile on first call)" : "STANDARD (eager full compile on include)")")
    println("  Tip:  Run once with Joovy ON, restart REPL with Joovy OFF, run again.")
    println("        Compare the 1st-call totals to see lazy vs eager compile cost.")
    println("=" ^ 70)
    println()

    return (first_call=times_1st, second_call=times_2nd, names=[n for (n,_) in BENCH_FUNCS],
            total_1st=total_1st, total_2nd=total_2nd, joovy=joovy_on)
end

run_benchmark()
