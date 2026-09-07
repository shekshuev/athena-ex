import { Chart, registerables } from "chart.js";

Chart.register(...registerables);

export const ChartsHooks = {};

// A single generic hook drives every Chart.js instance on the engagement
// dashboards - the server decides the chart's shape (type/data/options) as
// a plain JSON config in `data-config`, this hook only ever instantiates
// or destroys a `Chart`. That keeps every `*_config/2` builder in
// `AthenaWeb.ChartConfig` unit-testable as a pure function, with no
// chart-specific JS to keep in sync.
ChartsHooks.EngagementChart = {
  mounted() {
    this.renderChart();
  },

  updated() {
    this.renderChart();
  },

  destroyed() {
    if (this.chart) {
      this.chart.destroy();
      this.chart = null;
    }
  },

  renderChart() {
    if (this.chart) {
      this.chart.destroy();
      this.chart = null;
    }

    const config = JSON.parse(this.el.dataset.config);

    if (this.el.dataset.clickable === "true") {
      config.options = config.options || {};
      config.options.onClick = (_evt, elements) => {
        if (elements.length > 0) {
          this.pushEventTo(this.el, "chart_point_click", {
            chart: this.el.id,
            index: elements[0].index,
          });
        }
      };
    }

    this.chart = new Chart(this.el, config);
  },
};
