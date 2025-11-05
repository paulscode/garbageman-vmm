# Contributing to Garbageman NM

Thanks for your interest in contributing! This project helps manage Bitcoin Garbageman nodes in isolated VMs.

## How to Contribute

### Reporting Bugs

If you find a bug, please open an issue with:
- Your OS and shell version
- Steps to reproduce the issue
- Expected vs actual behavior
- Relevant log output or error messages

### Suggesting Features

Feature requests are welcome! Please open an issue describing:
- The problem you're trying to solve
- Your proposed solution
- Any alternative approaches you've considered

### Submitting Code

1. **Fork the repository** and create a branch for your changes
2. **Test thoroughly** - the script manages VMs and builds software, so test on a clean system if possible
3. **Follow the coding style**:
   - Use 4-space indentation (not tabs)
   - Add comments for complex logic
   - Use descriptive variable names
   - Follow bash best practices (shellcheck is your friend!)
4. **Update documentation** - if you change behavior, update README.md and inline comments
5. **Submit a pull request** with a clear description of your changes

### Code Style Guidelines

- **Functions**: Add header comments documenting purpose, parameters, and behavior
- **Error handling**: Use `set -euo pipefail` and check command success
- **User feedback**: Provide clear progress messages and error explanations
- **Safety**: Confirm destructive operations, provide undo/cleanup options

### Testing Checklist

Before submitting:
- [ ] Script runs without errors on a fresh system
- [ ] All menu options work as expected
- [ ] Comments are accurate and helpful
- [ ] README reflects any changed behavior
- [ ] No sensitive data (paths, IPs, keys) in commits

## Questions?

Open an issue for discussion - we're happy to help!

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
