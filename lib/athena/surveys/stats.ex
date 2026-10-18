defmodule Athena.Surveys.Stats do
  @moduledoc """
  The statistics behind the survey results: descriptives, correlations, group
  comparisons and scale reliability.

  Pure - no `Repo`, no assigns - which is what lets it be tested as a table of
  reference values rather than through a fixture. `Athena.Surveys.Results`
  does the SQL and calls in here for the numbers.

  ## Conventions worth knowing

  Every inferential function returns `{:ok, map}` or `{:error, reason}`, and
  never a number it cannot stand behind. A two-group comparison with one
  respondent in a group has no standard error; returning `0.0`, or a `p` of
  `1.0`, would be read as a finding. `:insufficient_data` and `:no_variance`
  say what actually happened.

  Variance and standard deviation are the **sample** versions (`n - 1`): the
  respondents are a sample of a cohort, not the cohort itself, and SPSS's
  defaults agree.

  Skewness and kurtosis use SPSS's `G1` and `G2`, not the simpler moment
  ratios, so a number copied out of this app matches the same data pasted into
  SPSS. Kurtosis is the **excess** kurtosis: `0` is normal, not `3`.

  Tests are two-tailed. A survey comparison is almost never directional in
  advance - "did these groups answer differently" is the question, and
  reporting a one-tailed p for it halves the p-value for free.
  """

  alias Athena.Surveys.Stats.Distributions, as: D

  @type values :: [number()]

  # -- descriptives ---------------------------------------------------------

  @doc """
  The usual summary of one numeric variable.

  Fields that are undefined for the data come back `nil` rather than zero:
  with two respondents there is no skewness, and `0.0` would claim a
  symmetric distribution that was never measured.
  """
  @spec descriptives(values()) :: map()
  def descriptives(values) do
    numbers = Enum.filter(values, &is_number/1)
    n = length(numbers)

    if n == 0 do
      %{
        n: 0,
        mean: nil,
        median: nil,
        modes: [],
        variance: nil,
        sd: nil,
        se: nil,
        min: nil,
        max: nil,
        q1: nil,
        q3: nil,
        iqr: nil,
        skewness: nil,
        kurtosis: nil
      }
    else
      mean = mean(numbers)
      variance = variance(numbers)
      sd = variance && :math.sqrt(variance)
      q1 = quantile(numbers, 0.25)
      q3 = quantile(numbers, 0.75)

      %{
        n: n,
        mean: mean,
        median: median(numbers),
        modes: modes(numbers),
        variance: variance,
        sd: sd,
        se: sd && n > 0 && sd / :math.sqrt(n),
        min: Enum.min(numbers),
        max: Enum.max(numbers),
        q1: q1,
        q3: q3,
        iqr: q1 && q3 && q3 - q1,
        skewness: skewness(numbers),
        kurtosis: kurtosis(numbers)
      }
    end
  end

  @doc "Arithmetic mean, or `nil` for no data."
  @spec mean(values()) :: float() | nil
  def mean([]), do: nil
  def mean(values), do: Enum.sum(values) / length(values)

  @doc "Sample variance (`n - 1`). `nil` below two values."
  @spec variance(values()) :: float() | nil
  def variance(values) when length(values) < 2, do: nil

  def variance(values) do
    m = mean(values)

    Enum.reduce(values, 0.0, fn value, acc -> acc + (value - m) * (value - m) end) /
      (length(values) - 1)
  end

  @doc "Sample standard deviation."
  @spec sd(values()) :: float() | nil
  def sd(values) do
    case variance(values) do
      nil -> nil
      v -> :math.sqrt(v)
    end
  end

  @doc "Median."
  @spec median(values()) :: float() | nil
  def median([]), do: nil

  def median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    middle = div(n, 2)

    if rem(n, 2) == 1 do
      Enum.at(sorted, middle) / 1
    else
      (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
    end
  end

  @doc """
  Every most-frequent value, sorted.

  A list rather than a single number on purpose: a five-point scale answered
  by a split cohort is genuinely bimodal, and picking one of the two peaks -
  as a `mode/1` returning a scalar must - hides the most interesting thing
  about the answer.
  """
  @spec modes(values()) :: values()
  def modes([]), do: []

  def modes(values) do
    counts = Enum.frequencies(values)
    highest = counts |> Map.values() |> Enum.max()

    counts
    |> Enum.filter(fn {_value, count} -> count == highest end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  @doc """
  The `p`-quantile by linear interpolation between order statistics (R's
  type 7, the most widely used definition).
  """
  @spec quantile(values(), float()) :: float() | nil
  def quantile([], _p), do: nil

  def quantile(values, p) when is_number(p) and p >= 0 and p <= 1 do
    sorted = Enum.sort(values)
    n = length(sorted)

    if n == 1 do
      hd(sorted) / 1
    else
      position = p * (n - 1)
      lower = trunc(position)
      upper = min(lower + 1, n - 1)
      weight = position - lower

      Enum.at(sorted, lower) * (1.0 - weight) + Enum.at(sorted, upper) * weight
    end
  end

  @doc """
  Sample skewness, SPSS's `G1`. Needs three values and some variance.
  """
  @spec skewness(values()) :: float() | nil
  def skewness(values) when length(values) < 3, do: nil

  def skewness(values) do
    n = length(values)
    m = mean(values)
    s = sd(values)

    if s in [nil, 0.0] do
      nil
    else
      sum = Enum.reduce(values, 0.0, fn value, acc -> acc + :math.pow((value - m) / s, 3) end)
      n / ((n - 1) * (n - 2)) * sum
    end
  end

  @doc """
  Sample excess kurtosis, SPSS's `G2` - `0` is normal. Needs four values.
  """
  @spec kurtosis(values()) :: float() | nil
  def kurtosis(values) when length(values) < 4, do: nil

  def kurtosis(values) do
    n = length(values)
    m = mean(values)
    s = sd(values)

    if s in [nil, 0.0] do
      nil
    else
      sum = Enum.reduce(values, 0.0, fn value, acc -> acc + :math.pow((value - m) / s, 4) end)

      n * (n + 1) / ((n - 1) * (n - 2) * (n - 3)) * sum -
        3 * :math.pow(n - 1, 2) / ((n - 2) * (n - 3))
    end
  end

  # -- correlation ----------------------------------------------------------

  @doc """
  Pearson's `r` with its two-tailed p-value.

  `{:error, :no_variance}` when either variable is constant: everyone giving
  the same answer is a real and interesting finding, but it is not a
  correlation of zero.
  """
  @spec pearson(values(), values()) :: {:ok, map()} | {:error, atom()}
  def pearson(xs, ys) when length(xs) != length(ys), do: {:error, :length_mismatch}
  def pearson(xs, _ys) when length(xs) < 3, do: {:error, :insufficient_data}

  def pearson(xs, ys) do
    n = length(xs)
    mx = mean(xs)
    my = mean(ys)

    {sxy, sxx, syy} =
      Enum.zip(xs, ys)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {sxy, sxx, syy} ->
        dx = x - mx
        dy = y - my
        {sxy + dx * dy, sxx + dx * dx, syy + dy * dy}
      end)

    if sxx == 0.0 or syy == 0.0 do
      {:error, :no_variance}
    else
      r = sxy / :math.sqrt(sxx * syy)
      {:ok, %{r: r, n: n, p: correlation_p(r, n), df: n - 2}}
    end
  end

  @doc """
  Spearman's rho - Pearson on the ranks, with tied values sharing their mean
  rank.

  The tie correction matters more here than anywhere else in this module:
  survey answers are mostly five-point scales, so ties are not an edge case,
  they are most of the data. Ranking ties arbitrarily instead would bias rho
  by an amount that depends on the order rows happened to come out of the
  database.
  """
  @spec spearman(values(), values()) :: {:ok, map()} | {:error, atom()}
  def spearman(xs, ys) when length(xs) != length(ys), do: {:error, :length_mismatch}
  def spearman(xs, _ys) when length(xs) < 3, do: {:error, :insufficient_data}

  def spearman(xs, ys) do
    case pearson(ranks(xs), ranks(ys)) do
      {:ok, result} -> {:ok, %{rho: result.r, n: result.n, p: result.p, df: result.df}}
      error -> error
    end
  end

  # A perfect correlation makes the t statistic infinite; the tail is zero and
  # the formula below would divide by zero reaching it.
  defp correlation_p(r, _n) when abs(r) >= 1.0, do: 0.0

  defp correlation_p(r, n) do
    df = n - 2
    t = r * :math.sqrt(df / (1.0 - r * r))
    D.t_p(t, df)
  end

  @doc """
  Ranks, with tied values sharing the mean of the ranks they span.
  """
  @spec ranks(values()) :: [float()]
  def ranks(values) do
    mean_ranks =
      values
      |> Enum.with_index(1)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.chunk_by(&elem(&1, 0))
      |> Enum.reduce({%{}, 1}, fn group, {acc, position} ->
        size = length(group)
        shared = (position + (position + size - 1)) / 2
        {Map.put(acc, group |> hd() |> elem(0), shared), position + size}
      end)
      |> elem(0)

    Enum.map(values, &Map.fetch!(mean_ranks, &1))
  end

  # -- contingency ----------------------------------------------------------

  @doc """
  Chi-square test of independence on a contingency table given as a list of
  rows.

  Reports `min_expected` and `small_expected_cells` alongside the statistic,
  because the test's whole validity rests on them: with expected counts below
  five the p-value is not trustworthy, and a dashboard that printed the number
  without saying so would be inviting a wrong conclusion.
  """
  @spec chi_square([[number()]]) :: {:ok, map()} | {:error, atom()}
  def chi_square(table) when is_list(table) and length(table) >= 2 do
    with :ok <- validate_table(table) do
      row_totals = Enum.map(table, &Enum.sum/1)
      col_totals = table |> Enum.zip_with(&Enum.sum/1)
      total = Enum.sum(row_totals)

      cond do
        total == 0 ->
          {:error, :insufficient_data}

        Enum.any?(row_totals, &(&1 == 0)) or Enum.any?(col_totals, &(&1 == 0)) ->
          # An empty row or column is not evidence of anything; it means the
          # table has fewer categories than it claims.
          {:error, :empty_margin}

        true ->
          chi_square_result(table, row_totals, col_totals, total)
      end
    end
  end

  def chi_square(_table), do: {:error, :insufficient_data}

  defp chi_square_result(table, row_totals, col_totals, total) do
    expected = expected_counts(row_totals, col_totals, total)
    statistic = chi_square_statistic(table, expected)

    rows = length(table)
    cols = length(col_totals)
    df = (rows - 1) * (cols - 1)
    flat_expected = List.flatten(expected)

    {:ok,
     %{
       chi_square: statistic,
       df: df,
       p: D.chi_square_p(statistic, df),
       n: total,
       cramers_v: :math.sqrt(statistic / (total * min(rows - 1, cols - 1))),
       expected: expected,
       min_expected: Enum.min(flat_expected),
       # The test's validity rests on these, so they travel with the
       # statistic rather than being left for a reader to work out.
       small_expected_cells: Enum.count(flat_expected, &(&1 < 5))
     }}
  end

  # What each cell would hold if the two variables were independent.
  defp expected_counts(row_totals, col_totals, total) do
    Enum.map(row_totals, fn row_total ->
      Enum.map(col_totals, &(row_total * &1 / total))
    end)
  end

  # Sum over every cell of (observed - expected)^2 / expected.
  defp chi_square_statistic(table, expected) do
    table
    |> Enum.zip(expected)
    |> Enum.flat_map(fn {observed_row, expected_row} -> Enum.zip(observed_row, expected_row) end)
    |> Enum.reduce(0.0, fn {observed, e}, acc -> acc + :math.pow(observed - e, 2) / e end)
  end

  defp validate_table(table) do
    widths = table |> Enum.map(&length/1) |> Enum.uniq()

    cond do
      widths == [] -> {:error, :insufficient_data}
      length(widths) > 1 -> {:error, :ragged_table}
      hd(widths) < 2 -> {:error, :insufficient_data}
      not Enum.all?(List.flatten(table), &is_number/1) -> {:error, :insufficient_data}
      true -> :ok
    end
  end

  # -- two groups -----------------------------------------------------------

  @doc """
  Independent-samples t test.

  Welch by default, and deliberately so: survey groups are almost never the
  same size or the same spread, and Student's test with unequal variances
  reports a p-value that is too small exactly when the groups differ most.
  Pass `variant: :student` for the pooled version when the equal-variance
  assumption is actually defensible.

  Also reports Cohen's `d`, because with a large cohort a difference of no
  practical size will still be "significant".
  """
  @spec t_test(values(), values(), keyword()) :: {:ok, map()} | {:error, atom()}
  def t_test(a, b, opts \\ [])

  def t_test(a, b, _opts) when length(a) < 2 or length(b) < 2,
    do: {:error, :insufficient_data}

  def t_test(a, b, opts) do
    variant = Keyword.get(opts, :variant, :welch)
    na = length(a)
    nb = length(b)
    ma = mean(a)
    mb = mean(b)
    va = variance(a)
    vb = variance(b)

    if va == 0.0 and vb == 0.0 do
      {:error, :no_variance}
    else
      {t, df} = t_statistic(variant, {ma, va, na}, {mb, vb, nb})

      {:ok,
       %{
         variant: variant,
         t: t,
         df: df,
         p: D.t_p(t, df),
         mean_a: ma,
         mean_b: mb,
         n_a: na,
         n_b: nb,
         cohens_d: cohens_d({ma, va, na}, {mb, vb, nb})
       }}
    end
  end

  defp t_statistic(:welch, {ma, va, na}, {mb, vb, nb}) do
    se_squared = va / na + vb / nb
    t = (ma - mb) / :math.sqrt(se_squared)

    df =
      :math.pow(se_squared, 2) /
        (:math.pow(va / na, 2) / (na - 1) + :math.pow(vb / nb, 2) / (nb - 1))

    {t, df}
  end

  defp t_statistic(:student, {ma, va, na}, {mb, vb, nb}) do
    df = na + nb - 2
    pooled = ((na - 1) * va + (nb - 1) * vb) / df
    t = (ma - mb) / :math.sqrt(pooled * (1 / na + 1 / nb))

    {t, df}
  end

  @doc "Cohen's `d` from two groups' means, variances and sizes."
  @spec cohens_d({number(), number(), pos_integer()}, {number(), number(), pos_integer()}) ::
          float() | nil
  def cohens_d({ma, va, na}, {mb, vb, nb}) do
    pooled = ((na - 1) * va + (nb - 1) * vb) / (na + nb - 2)

    if pooled <= 0.0, do: nil, else: (ma - mb) / :math.sqrt(pooled)
  end

  @doc """
  Mann-Whitney U, the rank-based alternative to the t test, with its normal
  approximation.

  Tie-corrected. On five-point scales ties dominate, and the uncorrected
  variance would overstate the spread of U and so understate every p-value.
  """
  @spec mann_whitney(values(), values()) :: {:ok, map()} | {:error, atom()}
  def mann_whitney(a, b) when length(a) < 2 or length(b) < 2, do: {:error, :insufficient_data}

  def mann_whitney(a, b) do
    na = length(a)
    nb = length(b)
    combined = a ++ b
    all_ranks = ranks(combined)
    rank_sum_a = all_ranks |> Enum.take(na) |> Enum.sum()

    u_a = rank_sum_a - na * (na + 1) / 2
    u_b = na * nb - u_a
    u = min(u_a, u_b)

    n = na + nb
    mu = na * nb / 2
    tie_term = tie_sum(combined)
    variance = na * nb / 12 * (n + 1 - tie_term / (n * (n - 1)))

    if variance <= 0.0 do
      # Every value identical: U is not random, so there is no test.
      {:error, :no_variance}
    else
      z = (u - mu) / :math.sqrt(variance)

      {:ok,
       %{
         u: u,
         u_a: u_a,
         u_b: u_b,
         z: z,
         p: D.normal_two_tailed(z),
         n_a: na,
         n_b: nb,
         rank_mean_a: rank_sum_a / na,
         rank_mean_b: (Enum.sum(all_ranks) - rank_sum_a) / nb
       }}
    end
  end

  # Sum of t^3 - t over tie groups, the term both rank tests correct by.
  defp tie_sum(values) do
    values
    |> Enum.frequencies()
    |> Map.values()
    |> Enum.reduce(0.0, fn count, acc -> acc + (count * count * count - count) end)
  end

  # -- many groups ----------------------------------------------------------

  @doc """
  One-way ANOVA, with eta-squared as the effect size.

  `{:error, :no_variance}` when nothing varies within *or* between groups -
  an F of `0/0` is not `0`.
  """
  @spec anova_one_way([values()]) :: {:ok, map()} | {:error, atom()}
  def anova_one_way(groups) when is_list(groups) do
    usable = Enum.reject(groups, &(&1 == []))

    cond do
      length(usable) < 2 ->
        {:error, :insufficient_data}

      Enum.sum(Enum.map(usable, &length/1)) - length(usable) < 1 ->
        # Every group has exactly one member: nothing to estimate error from.
        {:error, :insufficient_data}

      true ->
        all = List.flatten(usable)
        grand_mean = mean(all)
        n = length(all)
        k = length(usable)

        ss_between =
          Enum.reduce(usable, 0.0, fn group, acc ->
            acc + length(group) * :math.pow(mean(group) - grand_mean, 2)
          end)

        ss_within = Enum.reduce(usable, 0.0, fn group, acc -> acc + sum_of_squares(group) end)

        df_between = k - 1
        df_within = n - k

        if ss_within == 0.0 and ss_between == 0.0 do
          {:error, :no_variance}
        else
          anova_result(usable, ss_between, ss_within, df_between, df_within)
        end
    end
  end

  # Squared deviations from a group's own mean.
  defp sum_of_squares(values) do
    group_mean = mean(values)

    Enum.reduce(values, 0.0, fn value, acc -> acc + :math.pow(value - group_mean, 2) end)
  end

  defp anova_result(groups, ss_between, ss_within, df_between, df_within) do
    ms_between = ss_between / df_between
    ms_within = ss_within / df_within

    # Zero within-group variance with groups that differ is a perfect
    # separation: the F is infinite rather than 0/0, and saying so beats
    # inventing a number.
    f = if ms_within == 0.0, do: :infinity, else: ms_between / ms_within
    p = if f == :infinity, do: 0.0, else: D.f_p(f, df_between, df_within)

    {:ok,
     %{
       f: f,
       df_between: df_between,
       df_within: df_within,
       p: p,
       eta_squared: ss_between / (ss_between + ss_within),
       ss_between: ss_between,
       ss_within: ss_within,
       group_means: Enum.map(groups, &mean/1),
       group_sizes: Enum.map(groups, &length/1)
     }}
  end

  @doc """
  Kruskal-Wallis H, the rank-based alternative to ANOVA. Tie-corrected, for
  the same reason as `mann_whitney/2`.
  """
  @spec kruskal_wallis([values()]) :: {:ok, map()} | {:error, atom()}
  def kruskal_wallis(groups) when is_list(groups) do
    usable = Enum.reject(groups, &(&1 == []))

    if length(usable) < 2 or Enum.sum(Enum.map(usable, &length/1)) < 3 do
      {:error, :insufficient_data}
    else
      all = List.flatten(usable)
      n = length(all)
      all_ranks = ranks(all)

      {rank_sums, _rest} =
        Enum.map_reduce(usable, all_ranks, fn group, remaining ->
          {taken, rest} = Enum.split(remaining, length(group))
          {Enum.sum(taken), rest}
        end)

      h_raw =
        12 / (n * (n + 1)) *
          (Enum.zip(rank_sums, usable)
           |> Enum.reduce(0.0, fn {sum, group}, acc -> acc + sum * sum / length(group) end)) -
          3 * (n + 1)

      correction = 1.0 - tie_sum(all) / (n * n * n - n)

      if correction <= 0.0 do
        {:error, :no_variance}
      else
        h = h_raw / correction
        df = length(usable) - 1

        {:ok,
         %{
           h: h,
           df: df,
           p: D.chi_square_p(h, df),
           group_sizes: Enum.map(usable, &length/1),
           rank_means: Enum.zip_with(rank_sums, usable, fn sum, group -> sum / length(group) end)
         }}
      end
    end
  end

  # -- reliability ----------------------------------------------------------

  @doc """
  Cronbach's alpha over a battery of scale items - a `:multi_scale` matrix,
  in this app's terms.

  `items` is one list per item, each holding that item's value for the same
  respondents in the same order. Respondents with a gap in the battery have to
  be dropped by the caller before this point; alpha over different subsets per
  item is not alpha.

  Also reports, per item, the alpha the battery would have **without** it and
  its corrected item-total correlation. Those two together are what identify
  the item that is dragging a scale down, which is the only reason to compute
  alpha in the first place.
  """
  @spec cronbach_alpha([values()]) :: {:ok, map()} | {:error, atom()}
  def cronbach_alpha(items) when is_list(items) and length(items) >= 2 do
    lengths = items |> Enum.map(&length/1) |> Enum.uniq()

    cond do
      length(lengths) > 1 ->
        {:error, :length_mismatch}

      hd(lengths) < 2 ->
        {:error, :insufficient_data}

      true ->
        case alpha_of(items) do
          nil ->
            {:error, :no_variance}

          alpha ->
            {:ok,
             %{
               alpha: alpha,
               item_count: length(items),
               n: hd(lengths),
               items: item_statistics(items)
             }}
        end
    end
  end

  def cronbach_alpha(_items), do: {:error, :insufficient_items}

  defp alpha_of(items) when length(items) < 2, do: nil

  defp alpha_of(items) do
    k = length(items)
    totals = row_totals(items)
    total_variance = variance(totals)
    item_variance_sum = items |> Enum.map(&(variance(&1) || 0.0)) |> Enum.sum()

    if total_variance in [nil, 0.0] do
      nil
    else
      k / (k - 1) * (1.0 - item_variance_sum / total_variance)
    end
  end

  defp item_statistics(items) do
    items
    |> Enum.with_index()
    |> Enum.map(fn {item, index} ->
      others = List.delete_at(items, index)
      rest_totals = row_totals(others)

      %{
        index: index,
        mean: mean(item),
        sd: sd(item),
        # Corrected: against the rest of the battery, not against a total that
        # includes the item itself, which would correlate it with itself.
        item_total_r:
          case pearson(item, rest_totals) do
            {:ok, %{r: r}} -> r
            {:error, _reason} -> nil
          end,
        alpha_if_deleted: alpha_of(others)
      }
    end)
  end

  defp row_totals(items) do
    items
    |> Enum.zip_with(&Enum.sum/1)
  end

  # -- effect sizes ---------------------------------------------------------

  @doc """
  Plain-language size band for an effect, by the conventional cut-offs.

  Offered because a bare `0.31` means nothing to most readers, and the band
  is what makes a results page actionable. `:cohens_d`, `:eta_squared` and
  `:cramers_v` have different cut-offs, hence the kind.
  """
  @spec effect_band(:cohens_d | :eta_squared | :cramers_v, number() | nil) ::
          :negligible | :small | :medium | :large | nil
  def effect_band(_kind, nil), do: nil

  def effect_band(:cohens_d, value) do
    band(abs(value), 0.2, 0.5, 0.8)
  end

  def effect_band(:eta_squared, value) do
    band(abs(value), 0.01, 0.06, 0.14)
  end

  def effect_band(:cramers_v, value) do
    band(abs(value), 0.1, 0.3, 0.5)
  end

  defp band(value, small, medium, large) do
    cond do
      value < small -> :negligible
      value < medium -> :small
      value < large -> :medium
      true -> :large
    end
  end
end
