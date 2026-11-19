# Athena LMS

Athena is a learning management system for creating courses, organizing learning, and understanding student progress. It brings authoring, assessment, communication, and learning analytics into one platform.

> **Status: Active Development / Beta.** Athena is used in real educational settings and continues to evolve.

## Features

- **Course Authoring:** Create and organize courses, reuse learning materials, and share content with other authors.
- **Learning Paths:** Guide students through course material with flexible progression and access rules.
- **Assignments & Assessment:** Offer quizzes, exams, written assignments, and programming exercises, with automatic evaluation and instructor feedback.
- **Groups & Teaching:** Manage student groups and teams, assign courses, track progress, and review results.
- **Surveys & Feedback:** Collect feedback and explore responses to improve the learning experience.
- **Learning Analytics:** Understand engagement, identify difficulties, and support students who need attention.
- **Motivation & Achievements:** Encourage participation through achievements, challenges, and friendly competition.
- **Communication & Resources:** Keep students and instructors connected through messaging, announcements, and shared files.
- **Administration:** Manage users, roles, and access across the platform.

## Technology

Athena is built with Elixir, Phoenix LiveView, PostgreSQL, and Tailwind CSS. It is a modular monolith organized into bounded contexts, with module boundaries enforced by Boundary.

See the [development guide](docs/development.md) for architecture, the full stack, and environment requirements.

## Getting Started

Install Elixir/Erlang, Node.js, and Docker using the [development prerequisites](docs/development.md#prerequisites), then:

```bash
git clone https://github.com/shekshuev/athena-ex.git
cd athena-ex
docker compose -f docker-compose.infra.yml up -d
mix setup
iex -S mix phx.server
```

Open `http://localhost:4000`. In the running IEx session, create the first administrator using a password of your choice:

```elixir
Athena.Release.create_admin("admin", "ReplaceThisPassword123!")
```

Programming exercises require additional execution services. See [local code execution](docs/development.md#local-code-execution) for setup and platform limitations.

## Deployment

Athena provides Docker images and Compose configurations for deployment. Follow the [deployment guide](docs/development.md#deployment) to configure the application and execution services.

## Documentation

- **User and instructor guides:** Open `/docs` after signing in. Guides are available in English and Russian; their sources are in [priv/docs](priv/docs).
- **Development and operations:** See [docs/development.md](docs/development.md) for setup, architecture, testing, CI, and deployment.
- **Contributor and agent conventions:** Start with [AGENTS.md](AGENTS.md) and the [instruction index](.agents/00-index.md).

## Contributing

Issues and pull requests are welcome. Discuss major architectural changes before implementing them, and run `mix precommit` before submitting changes. See the [testing guide](docs/development.md#testing--code-quality) for additional checks and requirements.

## License

Athena is licensed under the Apache License 2.0. See [LICENCE](LICENCE).
