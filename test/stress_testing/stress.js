import ws from "k6/ws";
import http from "k6/http";
import { check, sleep } from "k6";

const targets = JSON.parse(open("./targets.json"));

const BASE_URL = "http://localhost:4000";
const TOTAL_VUS = 200;
const LOGIN_DELAY = 0.15;
const SYNC_TIME = TOTAL_VUS * LOGIN_DELAY + 5;

export const options = {
  scenarios: {
    athena_storm: {
      executor: "per-vu-iterations",
      vus: TOTAL_VUS,
      iterations: 1,
      maxDuration: "3m",
    },
  },
};

export default function () {
  const id = __VU;
  const username = `${targets.prefix}${id}`;

  sleep((id - 1) * LOGIN_DELAY);

  let res = http.get(`${BASE_URL}/`);
  const csrfToken = res.html().find('meta[name="csrf-token"]').attr("content");

  res = http.post(`${BASE_URL}/auth/log_in`, {
    _csrf_token: csrfToken,
    "user[login]": username,
    "user[password]": targets.password,
  });

  if (
    !check(res, {
      "authentication success": (r) => r.status === 200 || r.status === 302,
    })
  ) {
    return;
  }

  const playerUrl = `${BASE_URL}/learn/courses/${targets.course_id}/play/${targets.sec_id}`;
  res = http.get(playerUrl);

  const lvSession = res
    .html()
    .find("div[data-phx-main]")
    .attr("data-phx-session");
  const lvStatic = res
    .html()
    .find("div[data-phx-main]")
    .attr("data-phx-static");
  const phxId = res.html().find("div[data-phx-main]").attr("id");

  const currentTime = (id - 1) * LOGIN_DELAY;
  const waitTime = SYNC_TIME - currentTime - 2;
  if (waitTime > 0) sleep(waitTime);

  const wsUrl = `ws://localhost:4000/live/websocket?_csrf_token=${encodeURIComponent(csrfToken)}&v=2.0.0`;

  ws.connect(wsUrl, {}, function (socket) {
    socket.on("open", function () {
      socket.send(
        JSON.stringify({
          topic: `lv:${phxId}`,
          event: "phx_join",
          payload: {
            params: { _csrf_token: csrfToken },
            session: lvSession,
            static: lvStatic,
            url: playerUrl,
          },
          ref: "1",
        }),
      );

      socket.setTimeout(() => {
        socket.send(
          JSON.stringify({
            topic: `lv:${phxId}`,
            event: "event",
            payload: {
              type: "form",
              event: "submit_code",
              value: `block_id=${targets.block_id}&answer[code]=print(1)`,
            },
            ref: "2",
          }),
        );
      }, 200);
    });

    socket.on("message", (msg) => {
      if (msg.includes("accepted") || msg.includes("wrong_answer")) {
        socket.close();
      }
    });

    socket.setTimeout(() => socket.close(), 30000);
  });
}
