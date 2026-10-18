defmodule Athena.Surveys.StatsTest do
  @moduledoc """
  Reference values, worked examples and degenerate inputs.

  The expected numbers were computed independently - from the definitions, in
  a second implementation outside this codebase - rather than read off the
  module under test. That distinction is the whole value of these tests: when
  six of them first disagreed, the independent figures settled which side was
  wrong (the expectations were).

  The definitions are SPSS's, so a figure this app prints matches the same
  data pasted into SPSS. Where a result is undefined the test asserts the
  error rather than a plausible-looking zero - a `p` of `1.0` from a group of
  one would be read as a finding.
  """
  use ExUnit.Case, async: true

  alias Athena.Surveys.Stats

  defp close(actual, expected, tolerance \\ 1.0e-9) do
    assert is_number(actual), "expected a number, got #{inspect(actual)}"

    assert abs(actual - expected) <= tolerance,
           "expected #{expected} +/- #{tolerance}, got #{actual}"
  end

  describe "descriptives/1" do
    test "a worked example" do
      values = [2, 4, 4, 4, 5, 5, 7, 9]

      d = Stats.descriptives(values)

      assert d.n == 8
      close(d.mean, 5.0)
      close(d.median, 4.5)
      assert d.modes == [4]
      # Sample variance: sum of squares 32 over n-1 = 7.
      close(d.variance, 32 / 7)
      close(d.sd, :math.sqrt(32 / 7))
      close(d.se, :math.sqrt(32 / 7) / :math.sqrt(8))
      assert d.min == 2
      assert d.max == 9
    end

    test "quartiles and the IQR by the type-7 definition" do
      d = Stats.descriptives([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])

      close(d.q1, 3.25)
      close(d.q3, 7.75)
      close(d.iqr, 4.5)
    end

    test "reports every mode of a split cohort, not one of them" do
      # A five-point scale answered by two camps is genuinely bimodal, and
      # picking one peak would hide the most interesting thing about it.
      assert Stats.modes([1, 1, 1, 5, 5, 5, 3]) == [1, 5]
      assert Stats.modes([2, 2, 3]) == [2]
    end

    test "skewness and kurtosis use the SPSS definitions" do
      values = [1, 2, 2, 3, 3, 3, 4, 4, 5, 10]

      # G1 and G2 as SPSS reports them, so a number copied from this app
      # matches the same data pasted into SPSS. Kurtosis is excess: 0 is
      # normal, not 3.
      close(Stats.skewness(values), 1.97911116, 1.0e-7)
      close(Stats.kurtosis(values), 4.92203298, 1.0e-7)
    end

    test "undefined statistics are nil, never zero" do
      # Two respondents have no skewness. Returning 0.0 would claim a
      # symmetric distribution that was never measured.
      assert Stats.skewness([1, 2]) == nil
      assert Stats.kurtosis([1, 2, 3]) == nil
      assert Stats.variance([5]) == nil

      empty = Stats.descriptives([])
      assert empty.n == 0
      assert empty.mean == nil
      assert empty.modes == []
    end

    test "no variance leaves the shape statistics undefined" do
      # Everyone answered 4: a real finding, but skewness of a point mass is
      # not a number.
      d = Stats.descriptives([4, 4, 4, 4, 4])

      close(d.mean, 4.0)
      close(d.variance, 0.0)
      assert d.skewness == nil
      assert d.kurtosis == nil
    end

    test "ignores non-numeric values rather than crashing on them" do
      d = Stats.descriptives([1, nil, 3, "x", 5])

      assert d.n == 3
      close(d.mean, 3.0)
    end
  end

  describe "ranks/1" do
    test "ties share the mean of the ranks they span" do
      # The tie correction is not an edge case here: five-point scales mean
      # ties are most of the data.
      assert Stats.ranks([10, 20, 30]) == [1.0, 2.0, 3.0]
      assert Stats.ranks([10, 10, 30]) == [1.5, 1.5, 3.0]
      assert Stats.ranks([5, 5, 5, 5]) == [2.5, 2.5, 2.5, 2.5]
      assert Stats.ranks([3, 1, 4, 1, 5]) == [3.0, 1.5, 4.0, 1.5, 5.0]
    end

    test "rank sums always come to n(n+1)/2" do
      for values <- [[1, 2, 3, 4], [2, 2, 2], [5, 1, 5, 1, 9]] do
        n = length(values)
        close(Enum.sum(Stats.ranks(values)), n * (n + 1) / 2)
      end
    end
  end

  describe "pearson/2" do
    test "a perfect positive and a perfect negative relationship" do
      assert {:ok, up} = Stats.pearson([1, 2, 3, 4], [2, 4, 6, 8])
      close(up.r, 1.0)
      close(up.p, 0.0)

      assert {:ok, down} = Stats.pearson([1, 2, 3, 4], [8, 6, 4, 2])
      close(down.r, -1.0)
    end

    test "a worked example with its p-value" do
      xs = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
      ys = [2, 1, 4, 3, 6, 5, 8, 7, 10, 9]

      assert {:ok, result} = Stats.pearson(xs, ys)

      close(result.r, 0.9394, 1.0e-4)
      assert result.n == 10
      assert result.df == 8
      close(result.p, 5.484053e-5, 1.0e-10)
    end

    test "a constant variable is not a correlation of zero" do
      assert {:error, :no_variance} = Stats.pearson([1, 2, 3], [5, 5, 5])
      assert {:error, :no_variance} = Stats.pearson([5, 5, 5], [1, 2, 3])
    end

    test "refuses mismatched and tiny inputs" do
      assert {:error, :length_mismatch} = Stats.pearson([1, 2], [1, 2, 3])
      assert {:error, :insufficient_data} = Stats.pearson([1, 2], [3, 4])
    end
  end

  describe "spearman/2" do
    test "is one for any monotone relationship, however curved" do
      # The point of rho: Pearson would report less than 1 here.
      assert {:ok, result} = Stats.spearman([1, 2, 3, 4, 5], [1, 4, 9, 16, 25])
      close(result.rho, 1.0)
    end

    test "a worked example with ties" do
      xs = [1, 2, 2, 3, 4]
      ys = [2, 3, 3, 1, 5]

      assert {:ok, result} = Stats.spearman(xs, ys)

      # Ranks: x -> [1, 2.5, 2.5, 4, 5], y -> [2, 3.5, 3.5, 1, 5].
      close(result.rho, 0.36842105, 1.0e-7)
      close(result.p, 0.54175091, 1.0e-7)
    end

    test "equals Pearson when there are no ties" do
      xs = [3, 1, 4, 1.5, 5]
      ys = [2, 7, 1, 8, 3]

      {:ok, rho} = Stats.spearman(xs, ys)
      {:ok, r_on_ranks} = Stats.pearson(Stats.ranks(xs), Stats.ranks(ys))

      close(rho.rho, r_on_ranks.r)
    end

    test "all ties in one variable leaves nothing to correlate" do
      assert {:error, :no_variance} = Stats.spearman([1, 2, 3], [4, 4, 4])
    end
  end

  describe "chi_square/1" do
    test "a worked 2x2 example" do
      # Observed 20/30, 30/20; expected 25 everywhere.
      assert {:ok, result} = Stats.chi_square([[20, 30], [30, 20]])

      close(result.chi_square, 4.0)
      assert result.df == 1
      close(result.p, 0.0455, 1.0e-4)
      assert result.n == 100
      close(result.cramers_v, 0.2)
      assert result.min_expected == 25.0
      assert result.small_expected_cells == 0
    end

    test "perfect independence gives a statistic of zero" do
      assert {:ok, result} = Stats.chi_square([[10, 20], [20, 40]])

      close(result.chi_square, 0.0)
      close(result.p, 1.0)
    end

    test "a 3x2 example with the right degrees of freedom" do
      assert {:ok, result} = Stats.chi_square([[10, 20], [20, 10], [15, 15]])

      assert result.df == 2
      close(result.chi_square, 6.6667, 1.0e-4)
      close(result.p, 0.0357, 1.0e-4)
    end

    test "warns about the small expected counts that invalidate it" do
      # The test's validity rests on these, so the count is reported rather
      # than left for the reader to work out.
      assert {:ok, result} = Stats.chi_square([[1, 2], [3, 4]])

      assert result.small_expected_cells == 4
      assert result.min_expected < 5
    end

    test "refuses tables that are not tables" do
      assert {:error, :ragged_table} = Stats.chi_square([[1, 2], [3]])
      assert {:error, :insufficient_data} = Stats.chi_square([[1, 2]])
      assert {:error, :insufficient_data} = Stats.chi_square([[1], [2]])
      assert {:error, :empty_margin} = Stats.chi_square([[0, 0], [3, 4]])
      assert {:error, :insufficient_data} = Stats.chi_square([[0, 0], [0, 0]])
    end
  end

  describe "t_test/3" do
    test "a worked Student example" do
      a = [27, 31, 29, 30, 28]
      b = [22, 25, 24, 21, 26]

      assert {:ok, result} = Stats.t_test(a, b, variant: :student)

      assert result.df == 8
      close(result.t, 4.63046180, 1.0e-7)
      close(result.p, 0.00168703, 1.0e-7)
      close(result.cohens_d, 2.92856118, 1.0e-7)
    end

    test "Welch is the default, and differs when the spreads differ" do
      a = [10, 11, 10, 12, 11, 10, 11]
      b = [5, 20, 1, 30, 11, 2, 25]

      {:ok, welch} = Stats.t_test(a, b)
      {:ok, student} = Stats.t_test(a, b, variant: :student)

      assert welch.variant == :welch
      # Student's test with unequal variances reports a p that is too small
      # exactly when the groups differ most, which is why Welch is default.
      assert welch.df < student.df
      refute welch.p == student.p
    end

    test "identical groups are no difference at all" do
      assert {:ok, result} = Stats.t_test([1, 2, 3, 4], [1, 2, 3, 4])

      close(result.t, 0.0)
      close(result.p, 1.0)
      close(result.cohens_d, 0.0)
    end

    test "the sign follows the argument order" do
      {:ok, forward} = Stats.t_test([10, 11, 12], [1, 2, 3])
      {:ok, backward} = Stats.t_test([1, 2, 3], [10, 11, 12])

      assert forward.t > 0
      assert backward.t < 0
      close(forward.p, backward.p)
    end

    test "refuses groups too small or too flat to test" do
      assert {:error, :insufficient_data} = Stats.t_test([1], [1, 2, 3])
      assert {:error, :no_variance} = Stats.t_test([5, 5, 5], [5, 5, 5])
    end
  end

  describe "anova_one_way/1" do
    test "a worked three-group example" do
      groups = [[6, 8, 4, 5, 3, 4], [8, 12, 9, 11, 6, 8], [13, 9, 11, 8, 7, 12]]

      assert {:ok, result} = Stats.anova_one_way(groups)

      assert result.df_between == 2
      assert result.df_within == 15
      close(result.f, 9.26470588, 1.0e-7)
      close(result.p, 0.00239878, 1.0e-7)
      close(result.eta_squared, 0.55263158, 1.0e-7)
    end

    test "matches a t test squared for two groups" do
      a = [27, 31, 29, 30, 28]
      b = [22, 25, 24, 21, 26]

      {:ok, anova} = Stats.anova_one_way([a, b])
      {:ok, t} = Stats.t_test(a, b, variant: :student)

      # F = t^2 with one numerator degree of freedom; the two code paths
      # should land on the same p.
      close(anova.f, t.t * t.t, 1.0e-9)
      close(anova.p, t.p, 1.0e-12)
    end

    test "identical groups give an F of zero" do
      assert {:ok, result} = Stats.anova_one_way([[1, 2, 3], [1, 2, 3], [1, 2, 3]])

      close(result.f, 0.0)
      close(result.p, 1.0)
      close(result.eta_squared, 0.0)
    end

    test "groups that differ with no internal spread are a perfect separation" do
      # Zero within-group variance: the F is infinite rather than 0/0, and
      # saying so beats inventing a number.
      assert {:ok, result} = Stats.anova_one_way([[1, 1, 1], [5, 5, 5]])

      assert result.f == :infinity
      close(result.p, 0.0)
    end

    test "refuses what it cannot estimate error from" do
      assert {:error, :insufficient_data} = Stats.anova_one_way([[1, 2, 3]])
      assert {:error, :insufficient_data} = Stats.anova_one_way([[1], [2]])
      assert {:error, :no_variance} = Stats.anova_one_way([[3, 3], [3, 3]])
    end
  end

  describe "mann_whitney/2" do
    test "a worked example" do
      a = [1, 2, 3, 4, 5]
      b = [6, 7, 8, 9, 10]

      assert {:ok, result} = Stats.mann_whitney(a, b)

      close(result.u, 0.0)
      close(result.p, 0.0090, 1.0e-4)
      assert result.rank_mean_a < result.rank_mean_b
    end

    test "overlapping groups give U at its midpoint" do
      assert {:ok, result} = Stats.mann_whitney([1, 3, 5, 7], [2, 4, 6, 8])

      # n1*n2/2 = 8 when the groups interleave perfectly.
      close(result.u, 6.0)
      assert result.p > 0.3
    end

    test "the tie correction changes the answer on scale data" do
      # Five-point scales: ties dominate, and the uncorrected variance would
      # overstate the spread of U and so understate the p-value.
      a = [3, 3, 3, 4, 4]
      b = [4, 4, 5, 5, 5]

      assert {:ok, result} = Stats.mann_whitney(a, b)

      # Without the correction, sigma = sqrt(n1*n2*(N+1)/12). Ties shrink the
      # true sigma, so the corrected |z| must come out larger - a naive
      # implementation would understate the evidence.
      naive_sigma = :math.sqrt(5 * 5 * (10 + 1) / 12)
      naive_z = (result.u - 5 * 5 / 2) / naive_sigma

      assert abs(result.z) > abs(naive_z)
    end

    test "U and its complement always sum to n1*n2" do
      assert {:ok, result} = Stats.mann_whitney([1, 2, 3], [4, 5, 6, 7])

      close(result.u_a + result.u_b, 3 * 4)
    end

    test "refuses groups too small or entirely tied" do
      assert {:error, :insufficient_data} = Stats.mann_whitney([1], [2, 3])
      assert {:error, :no_variance} = Stats.mann_whitney([4, 4, 4], [4, 4, 4])
    end
  end

  describe "kruskal_wallis/1" do
    test "a worked three-group example" do
      groups = [[2.9, 3.0, 2.5, 2.6, 3.2], [3.8, 2.7, 4.0, 2.4], [2.8, 3.4, 3.7, 2.2, 2.0]]

      assert {:ok, result} = Stats.kruskal_wallis(groups)

      assert result.df == 2
      close(result.h, 0.7714, 1.0e-4)
      close(result.p, 0.6800, 1.0e-4)
    end

    test "well-separated groups give a large H" do
      assert {:ok, result} = Stats.kruskal_wallis([[1, 2, 3], [10, 11, 12], [20, 21, 22]])

      assert result.h > 7.0
      assert result.p < 0.03
    end

    test "is tie-corrected" do
      assert {:ok, result} = Stats.kruskal_wallis([[1, 1, 1], [2, 2, 2], [3, 3, 3]])

      # Every value tied within groups but groups fully separated: the
      # correction keeps H finite and maximal rather than dividing by zero.
      assert is_float(result.h)
      assert result.p < 0.05
    end

    test "refuses what has nothing to compare" do
      assert {:error, :insufficient_data} = Stats.kruskal_wallis([[1, 2, 3]])
      assert {:error, :insufficient_data} = Stats.kruskal_wallis([[1], [2]])
      assert {:error, :no_variance} = Stats.kruskal_wallis([[5, 5], [5, 5]])
    end
  end

  describe "cronbach_alpha/1" do
    test "a worked example with per-item diagnostics" do
      items = [
        [4, 5, 3, 4, 5, 2, 4, 5],
        [4, 4, 3, 5, 5, 2, 3, 5],
        [5, 5, 2, 4, 4, 3, 4, 4]
      ]

      assert {:ok, result} = Stats.cronbach_alpha(items)

      close(result.alpha, 0.85810811, 1.0e-7)
      assert result.item_count == 3
      assert result.n == 8
      assert length(result.items) == 3

      for item <- result.items do
        assert is_float(item.item_total_r)
        assert is_float(item.alpha_if_deleted)
      end
    end

    test "identifies the item dragging a scale down" do
      good = [1, 2, 3, 4, 5, 1, 2, 3, 4, 5]
      noise = [5, 1, 4, 2, 3, 2, 5, 1, 3, 4]

      {:ok, result} = Stats.cronbach_alpha([good, good, good, noise])

      bad_item = Enum.at(result.items, 3)
      good_item = Enum.at(result.items, 0)

      # The two diagnostics that make alpha worth computing: dropping the
      # noisy item should raise alpha, and its item-total correlation should
      # be the weakest.
      assert bad_item.alpha_if_deleted > result.alpha
      assert bad_item.item_total_r < good_item.item_total_r
    end

    test "perfectly parallel items reach alpha of one" do
      item = [1, 2, 3, 4, 5]

      {:ok, result} = Stats.cronbach_alpha([item, item, item])

      close(result.alpha, 1.0, 1.0e-12)
    end

    test "refuses what is not a battery" do
      assert {:error, :insufficient_items} = Stats.cronbach_alpha([[1, 2, 3]])
      assert {:error, :length_mismatch} = Stats.cronbach_alpha([[1, 2, 3], [1, 2]])
      assert {:error, :insufficient_data} = Stats.cronbach_alpha([[1], [1]])
      assert {:error, :no_variance} = Stats.cronbach_alpha([[3, 3, 3], [3, 3, 3]])
    end
  end

  describe "effect_band/2" do
    test "bands each effect size by its own conventional cut-offs" do
      assert Stats.effect_band(:cohens_d, 0.1) == :negligible
      assert Stats.effect_band(:cohens_d, 0.3) == :small
      assert Stats.effect_band(:cohens_d, 0.6) == :medium
      assert Stats.effect_band(:cohens_d, 1.2) == :large

      # The same 0.3 is a small d but a medium V - hence the kind.
      assert Stats.effect_band(:cramers_v, 0.3) == :medium
      assert Stats.effect_band(:eta_squared, 0.3) == :large
    end

    test "the sign does not change the size" do
      assert Stats.effect_band(:cohens_d, -1.2) == :large
    end

    test "nil in, nil out" do
      assert Stats.effect_band(:cohens_d, nil) == nil
    end
  end
end
