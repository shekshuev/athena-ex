defmodule Athena.Surveys.Stats.DistributionsTest do
  @moduledoc """
  Pinned against published critical values.

  This is the one place in the feature where a subtle bug produces a number
  that looks like science and is not, so the tests are reference values rather
  than properties: each row is a critical value from a standard table, and the
  tail at that point must come back as the stated alpha.
  """
  use ExUnit.Case, async: true

  alias Athena.Surveys.Stats.Distributions, as: D

  defp close(actual, expected, tolerance) do
    assert is_float(actual), "expected a float, got #{inspect(actual)}"

    assert abs(actual - expected) <= tolerance,
           "expected #{expected} +/- #{tolerance}, got #{actual}"
  end

  describe "log_gamma/1" do
    test "matches the factorials it generalises" do
      # Γ(n) = (n-1)!
      for {n, factorial} <- [{1, 1}, {2, 1}, {3, 2}, {4, 6}, {5, 24}, {11, 3_628_800}] do
        close(D.log_gamma(n), :math.log(factorial), 1.0e-10)
      end
    end

    test "matches the half-integer values" do
      # Γ(1/2) = sqrt(pi), Γ(3/2) = sqrt(pi)/2
      close(D.log_gamma(0.5), :math.log(:math.sqrt(:math.pi())), 1.0e-12)
      close(D.log_gamma(1.5), :math.log(:math.sqrt(:math.pi()) / 2.0), 1.0e-12)
    end

    test "stays finite where a plain gamma would overflow" do
      # Γ(200) is far past a float; its log is not. Contingency tables of this
      # size are ordinary.
      assert D.log_gamma(200.0) > 800.0
      assert is_float(D.log_gamma(1000.0))
    end

    test "is nil rather than an exception for an undefined input" do
      assert D.log_gamma(0) == nil
      assert D.log_gamma(-1.0) == nil
      assert D.log_gamma("two") == nil
    end
  end

  describe "erf/1" do
    test "matches known values" do
      close(D.erf(0), 0.0, 1.0e-15)
      close(D.erf(0.5), 0.5204998778, 1.0e-9)
      close(D.erf(1.0), 0.8427007929, 1.0e-9)
      close(D.erf(2.0), 0.9953222650, 1.0e-9)
      close(D.erf(3.0), 0.9999779095, 1.0e-9)
    end

    test "is odd" do
      for x <- [0.3, 1.0, 2.5] do
        close(D.erf(-x), -D.erf(x), 1.0e-15)
      end
    end
  end

  describe "normal_cdf/1" do
    test "matches the z table" do
      close(D.normal_cdf(0.0), 0.5, 1.0e-12)
      close(D.normal_cdf(1.0), 0.8413447461, 1.0e-9)
      close(D.normal_cdf(1.644854), 0.95, 1.0e-6)
      close(D.normal_cdf(1.959964), 0.975, 1.0e-6)
      close(D.normal_cdf(2.326348), 0.99, 1.0e-6)
      close(D.normal_cdf(-1.959964), 0.025, 1.0e-6)
    end

    test "the two-tailed p at the classic critical values" do
      close(D.normal_two_tailed(1.959964), 0.05, 1.0e-6)
      close(D.normal_two_tailed(2.575829), 0.01, 1.0e-6)
      close(D.normal_two_tailed(0.0), 1.0, 1.0e-12)
    end
  end

  describe "chi_square_p/2" do
    test "matches the chi-square table at alpha = 0.05" do
      for {df, critical} <- [
            {1, 3.8415},
            {2, 5.9915},
            {3, 7.8147},
            {4, 9.4877},
            {5, 11.0705},
            {10, 18.3070},
            {20, 31.4104},
            {50, 67.5048}
          ] do
        close(D.chi_square_p(critical, df), 0.05, 5.0e-5)
      end
    end

    test "matches the table at alpha = 0.01 and 0.001" do
      close(D.chi_square_p(6.6349, 1), 0.01, 5.0e-5)
      close(D.chi_square_p(9.2103, 2), 0.01, 5.0e-5)
      close(D.chi_square_p(10.8276, 1), 0.001, 5.0e-5)
      close(D.chi_square_p(13.8155, 2), 0.001, 5.0e-5)
    end

    test "a statistic of zero is no evidence at all" do
      close(D.chi_square_p(0.0, 1), 1.0, 1.0e-12)
      close(D.chi_square_p(0.0, 7), 1.0, 1.0e-12)
    end

    test "is monotonic: a bigger statistic is never weaker evidence" do
      ps = Enum.map([0.5, 1.0, 2.0, 4.0, 8.0, 16.0], &D.chi_square_p(&1, 3))

      assert ps == Enum.sort(ps, :desc)
    end

    test "nil for a nonsensical input instead of raising" do
      assert D.chi_square_p(-1.0, 3) == nil
      assert D.chi_square_p(3.0, 0) == nil
    end
  end

  describe "t_p/2" do
    test "matches the t table at two-tailed alpha = 0.05" do
      for {df, critical} <- [
            {1, 12.7062},
            {2, 4.3027},
            {5, 2.5706},
            {10, 2.2281},
            {20, 2.0860},
            {30, 2.0423},
            {100, 1.9840},
            {1000, 1.9623}
          ] do
        close(D.t_p(critical, df), 0.05, 5.0e-5)
      end
    end

    test "matches the table at two-tailed alpha = 0.01" do
      close(D.t_p(63.6567, 1), 0.01, 5.0e-5)
      close(D.t_p(3.1693, 10), 0.01, 5.0e-5)
      close(D.t_p(2.7045, 40), 5.0e-3 * 2, 5.0e-5)
    end

    test "approaches the normal as the degrees of freedom grow" do
      # With df in the thousands the t tail and the z tail should agree to
      # several digits - a good end-to-end check on both code paths.
      close(D.t_p(1.959964, 100_000), D.normal_two_tailed(1.959964), 1.0e-4)
    end

    test "a statistic of zero is no evidence, and the sign does not matter" do
      close(D.t_p(0.0, 10), 1.0, 1.0e-12)
      close(D.t_p(-2.2281, 10), D.t_p(2.2281, 10), 1.0e-15)
    end

    test "nil for invalid degrees of freedom" do
      assert D.t_p(2.0, 0) == nil
      assert D.t_p(2.0, -3) == nil
    end
  end

  describe "f_p/3" do
    test "matches the F table at alpha = 0.05" do
      for {df1, df2, critical} <- [
            {1, 10, 4.9646},
            {2, 10, 4.1028},
            {3, 12, 3.4903},
            {5, 20, 2.7109},
            {1, 1, 161.4476},
            {4, 30, 2.6896},
            {10, 100, 1.9267}
          ] do
        close(D.f_p(critical, df1, df2), 0.05, 5.0e-4)
      end
    end

    test "matches the table at alpha = 0.01" do
      close(D.f_p(10.0443, 1, 10), 0.01, 5.0e-4)
      close(D.f_p(5.9525, 3, 12), 0.01, 5.0e-4)
    end

    test "agrees with chi-square as the denominator df grows" do
      # F(k, inf) * k -> chi-square(k): another cross-check between the beta
      # and gamma code paths.
      close(D.f_p(2.0, 3, 1_000_000), D.chi_square_p(6.0, 3), 1.0e-3)
    end

    test "squares a t: F(1, df) at t^2 is the two-tailed t at t" do
      for {t, df} <- [{2.2281, 10}, {2.0423, 30}, {1.9840, 100}] do
        close(D.f_p(t * t, 1, df), D.t_p(t, df), 1.0e-9)
      end
    end

    test "nil for invalid degrees of freedom" do
      assert D.f_p(2.0, 0, 10) == nil
      assert D.f_p(2.0, 3, 0) == nil
      assert D.f_p(-1.0, 3, 10) == nil
    end
  end

  describe "the incomplete functions directly" do
    test "gamma_p is a CDF: 0 at 0, approaching 1" do
      close(D.gamma_p(2.0, 0.0), 0.0, 1.0e-15)
      assert D.gamma_p(2.0, 100.0) > 0.999999
      close(D.gamma_p(1.0, 1.0), 1.0 - :math.exp(-1.0), 1.0e-12)
    end

    test "gamma_p and gamma_q sum to one across the series/fraction boundary" do
      # The two branches meet at x = a + 1; a discontinuity there would be
      # invisible in the tables above but wrong everywhere near it.
      for a <- [0.5, 1.0, 3.0, 10.0], x <- [0.5, 1.0, 3.9, 4.0, 4.1, 11.0, 20.0] do
        close(D.gamma_p(a, x) + D.gamma_q(a, x), 1.0, 1.0e-12)
      end
    end

    test "beta_inc is a CDF with the expected symmetry" do
      close(D.beta_inc(2.0, 3.0, 0.0), 0.0, 1.0e-15)
      close(D.beta_inc(2.0, 3.0, 1.0), 1.0, 1.0e-15)

      # I_x(a,b) = 1 - I_(1-x)(b,a), including across the branch swap.
      for a <- [0.5, 2.0, 7.0], b <- [0.5, 3.0, 9.0], x <- [0.1, 0.3, 0.5, 0.7, 0.9] do
        close(D.beta_inc(a, b, x) + D.beta_inc(b, a, 1.0 - x), 1.0, 1.0e-10)
      end
    end

    test "beta_inc matches the uniform case" do
      # I_x(1,1) = x
      for x <- [0.1, 0.25, 0.5, 0.75, 0.9] do
        close(D.beta_inc(1.0, 1.0, x), x, 1.0e-12)
      end
    end

    test "nil for out-of-domain parameters" do
      assert D.gamma_p(0.0, 1.0) == nil
      assert D.gamma_p(1.0, -1.0) == nil
      assert D.beta_inc(0.0, 1.0, 0.5) == nil
      assert D.beta_inc(1.0, 0.0, 0.5) == nil
    end
  end
end
