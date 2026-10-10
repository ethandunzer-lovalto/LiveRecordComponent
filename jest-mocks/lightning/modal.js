import { LightningElement } from "lwc";

// Stand-in for lightning/modal, which sfdx-lwc-jest doesn't stub. open() is a mock that subclasses share: tests set
// what it resolves with. close() dispatches a 'modalclose' event with the result, so tests can see how a modal closed.
export default class LightningModal extends LightningElement {
  static open = jest.fn(() => Promise.resolve());

  close(result) {
    this.dispatchEvent(new CustomEvent("modalclose", { detail: result }));
  }
}
