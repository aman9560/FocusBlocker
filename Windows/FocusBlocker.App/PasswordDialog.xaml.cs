using System.Windows;

namespace FocusBlocker.App;

public partial class PasswordDialog : Window
{
    public string PasswordValue => PasswordInput.Password;
    public PasswordDialog(string prompt) { InitializeComponent(); PromptText.Text = prompt; Loaded += (_, _) => PasswordInput.Focus(); }
    private void Continue_Click(object sender, RoutedEventArgs e) => DialogResult = true;
}
