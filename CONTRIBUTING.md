# Contributing to Flux

Thank you for your interest in contributing to Flux! We welcome contributions from everyone.

## Getting Started

1. **Fork the repository** on GitHub.
2. **Clone your fork** locally:
   ```bash
   git clone https://github.com/your-username/flux.git
   cd flux
   ```
3. **Setup Secrets**:
   - Copy `flux/Services/SecretsExample.txt` to `flux/Services/Secrets.swift`.
   - Optionally add your own TMDB API Key (or enter it in Settings → General inside the app).

4. **Open the project** in Xcode:
   ```bash
   open flux.xcodeproj
   ```

## Development Workflow

- **Branching**: Create a new branch for each feature or bug fix:
  ```bash
  git checkout -b feature/my-new-feature
  ```
- **Style**: Follow standard Swift and SwiftUI guidelines.
- **Localization**: Follow the 10-language matrix in `flux/Services/LanguageManager.swift` (`en`, `ja`, `es`, `fr`, `de`, `it`, `pt`, `ko`, `hi`, `zh`). Avoid hardcoding user-facing strings in UI views.
- **Testing**: Verify your changes compile and pass tests:
  ```bash
  xcodebuild -project flux.xcodeproj -scheme flux -destination 'platform=macOS' test
  ```

## Submitting Changes

1. Push your changes to your fork.
2. Submit a **Pull Request** to the `main` branch.
3. Describe your changes clearly in the PR description.

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
