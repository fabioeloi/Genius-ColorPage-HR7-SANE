Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$targets = @(Get-Process -Name setup-x86_64,zadig-2.9 -ErrorAction SilentlyContinue)
foreach ($target in $targets) {
    Write-Output "Process $($target.ProcessName) PID=$($target.Id)"
    $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $target.Id)
    $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)
    foreach ($window in $windows) {
        $elements = $window.FindAll([System.Windows.Automation.TreeScope]::Subtree, [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($element in $elements) {
            $current = $element.Current
            '{0} | {1} | {2}' -f $current.ControlType.ProgrammaticName, $current.AutomationId, $current.Name
        }
    }
}
