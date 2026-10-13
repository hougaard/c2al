page 50100 "C2AL Examples"
{
    Caption = 'c2al Examples';
    PageType = Card;
    ApplicationArea = All;
    UsageCategory = Tasks;
    Editable = false;

    layout
    {
        area(Content)
        {
            group(Summary)
            {
                Caption = 'Summary';
                field(PassedField; Passed)
                {
                    Caption = 'Passed';
                    ToolTip = 'Tests whose AL result matched the expected value.';
                }
                field(FailedField; Failed)
                {
                    Caption = 'Failed';
                    ToolTip = 'Tests whose AL result did not match the expected value.';
                    Style = Unfavorable;
                    StyleExpr = Failed > 0;
                }
            }
            group(Details)
            {
                Caption = 'Results';
                field(ReportField; ReportText)
                {
                    Caption = 'Report';
                    ToolTip = 'One line per test: ok/FAIL, the call, and the result. Each example ends with its run time.';
                    MultiLine = true;
                    ShowCaption = false;
                }
            }
        }
    }

    actions
    {
        area(Processing)
        {
            action(RunAll)
            {
                Caption = 'Run all examples';
                ToolTip = 'Runs the tests of every example (the same tests as tests/run_tests.py) in AL.';
                Image = Start;
                Promoted = true;
                PromotedCategory = Process;
                PromotedOnly = true;

                trigger OnAction()
                var
                    Tests: Codeunit "C2AL Example Tests";
                begin
                    Passed := 0;
                    Failed := 0;
                    ReportText := Tests.RunAll(Passed, Failed);
                    CurrPage.Update(false);
                end;
            }
        }
    }

    var
        ReportText: Text;
        Passed: Integer;
        Failed: Integer;
}
