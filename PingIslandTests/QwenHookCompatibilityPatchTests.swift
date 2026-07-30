import XCTest
@testable import NotchCode

final class QwenHookCompatibilityPatchTests: XCTestCase {
    func testPatchedQwenCLISourceInjectsAnswerPayloadIntoHookHandledPaths() {
        let source = """
                  if (hookResult.hasDecision) {
                    if (hookResult.shouldAllow) {
                      if (hookResult.updatedInput && typeof reqInfo.args === "object") {
                        this.setArgsInternal(reqInfo.callId, hookResult.updatedInput);
                      }
                      await confirmationDetails.onConfirm(ToolConfirmationOutcome.ProceedOnce);
                    }
                  }

                  if (hookResult.hasDecision) {
                    hookHandled = true;
                    if (hookResult.shouldAllow) {
                      if (hookResult.updatedInput) {
                        args2 = hookResult.updatedInput;
                        invocation.params = hookResult.updatedInput;
                      }
                      await confirmationDetails.onConfirm(
                        ToolConfirmationOutcome.ProceedOnce
                      );
                    }
                  }
        """

        let patched = HookInstaller.patchedQwenCLISourceIfNeeded(source)

        XCTAssertNotNil(patched)
        XCTAssertTrue(patched?.contains("const hookAnswerPayload = confirmationDetails.type === \"ask_user_question\"") ?? false)
        XCTAssertTrue(patched?.contains("await confirmationDetails.onConfirm(ToolConfirmationOutcome.ProceedOnce, hookAnswerPayload);") ?? false)
        XCTAssertTrue(patched?.contains("hookAnswerPayload") ?? false)
    }

    func testPatchedQwenCLISourceSkipsAlreadyPatchedSource() {
        let source = """
        const hookAnswerPayload = confirmationDetails.type === "ask_user_question" && hookResult.updatedInput && typeof hookResult.updatedInput === "object" && "answers" in hookResult.updatedInput ? { answers: hookResult.updatedInput.answers } : void 0;
        """

        let patched = HookInstaller.patchedQwenCLISourceIfNeeded(source)

        XCTAssertEqual(patched, source)
    }

    func testPatchedCodeBuddyCLISourceReturnsNotificationHookResultAndAppliesAskAnswer() {
        let source = """
        var tF=el(80699),tV=el(38195);
        async executeNotificationHooks(ei,ea,el){try{await this.terminalNotificationService.sendNotification(ea,rf.PRODUCT_CLI_NAME,el,ei)}catch(ei){this.logger.warn?.("Failed to send terminal notification:",ei)}if(!await this.hookManager.hasHooks(tV.HookEvent.NOTIFICATION))return;let ec={session_id:ei?.id,session:ei,transcript_path:ei?this.sessionStore.getSessionFilePath(ei.id):"",cwd:tJ.PathUtils.getWorkDir(),hook_event_name:"Notification",message:ea,notification_type:el,title:rf.PRODUCT_CLI_NAME};try{await this.hookManager.executeHooks(tV.HookEvent.NOTIFICATION,ec)}catch(ei){this.logger.error("Notification hook execution failed:",ei)}}async executeSubagentStartHooks(ei){}
        async handle(ei,ea,ec,em,e_){let eA=em.rawItem.callId||em.rawItem.id;let eu=`needs your permission to use ${ea}`;try{await this.sessionHookManager.executeNotificationHooks(ei,eu,tV.NotificationType.PERMISSION_PROMPT)}catch(ei){this.consoleManager.error("Notification hook failed:",ei)}}else await this.requestSdkPermission(ei,em,ea,e_);
        """

        let patched = HookInstaller.patchedCodeBuddyCLISourceIfNeeded(source)

        XCTAssertNotNil(patched)
        XCTAssertTrue(patched?.contains("return await this.hookManager.executeHooks(tV.HookEvent.NOTIFICATION,ec)") == true)
        XCTAssertTrue(patched?.contains("[PingIsland CodeBuddy CLI AskUserQuestion compatibility]") == true)
        XCTAssertTrue(patched?.contains("tF.ContainerUtil.get(el(88056).AskService).doneAsk(eN,eM)") == true)
        XCTAssertTrue(patched?.contains("this.approve(em)") == true)
    }

    func testPatchedCodeBuddyCLISourceSupportsHeadlessContainerAlias() {
        let source = """
        var t$=el(80699),tV=el(38195);
        async executeNotificationHooks(ei,ea,el){try{await this.terminalNotificationService.sendNotification(ea,rh.PRODUCT_CLI_NAME,el,ei)}catch(ei){this.logger.warn?.("Failed to send terminal notification:",ei)}if(!await this.hookManager.hasHooks(tV.HookEvent.NOTIFICATION))return;let ec={session_id:ei?.id,session:ei,transcript_path:ei?this.sessionStore.getSessionFilePath(ei.id):"",cwd:tK.PathUtils.getWorkDir(),hook_event_name:"Notification",message:ea,notification_type:el,title:rh.PRODUCT_CLI_NAME};try{await this.hookManager.executeHooks(tV.HookEvent.NOTIFICATION,ec)}catch(ei){this.logger.error("Notification hook execution failed:",ei)}}async executeSubagentStartHooks(ei){}
        async handle(ei,ea,ec,em,e_){let ev=em.rawItem.callId||em.rawItem.id;let eu=`needs your permission to use ${ea}`;try{await this.sessionHookManager.executeNotificationHooks(ei,eu,tV.NotificationType.PERMISSION_PROMPT)}catch(ei){this.consoleManager.error("Notification hook failed:",ei)}}else await this.requestSdkPermission(ei,em,ea,e_);
        """

        let patched = HookInstaller.patchedCodeBuddyCLISourceIfNeeded(source)

        XCTAssertNotNil(patched)
        XCTAssertTrue(patched?.contains("t$.ContainerUtil.get(el(88056).AskService).doneAsk(eN,eM)") == true)
    }

    func testPatchedCodeBuddyCLISourceSkipsAlreadyPatchedSource() {
        let source = """
        [PingIsland CodeBuddy CLI AskUserQuestion compatibility]
        """

        let patched = HookInstaller.patchedCodeBuddyCLISourceIfNeeded(source)

        XCTAssertEqual(patched, source)
    }
}
