//! The creator-fee recipient (DESIGN-stellar-contracts-v2 §5.4, §5.5, L14).
//!
//! - The current recipient can hand the role on at once (`transfer_creator_fee_recipient`).
//! - The admin can propose a takeover: it executes from `takeover_delay` after the proposal until `takeover_window`
//!   later, by anyone, unless the admin or the current recipient cancels it first (the recipient's veto). The proposal
//!   lives in temporary storage and lapses with its window.
//! - On any change, the curve fees booked so far stay with the old recipient: they move to `CreatorOwed(old, quote)`,
//!   which anyone can pay out to it with `claim_owed` (L14), as Monad credits curve fees at accrual
//!   (M:contracts/src/BondingCurve.sol:291-319). **Declared exception (F3):** LP fee growth the locker hasn't harvested
//!   yet at the change goes to the recipient current at each later harvest, as Monad's hook pays unswept fees to the
//!   recipient at sweep time. The launchpad can't snapshot it: harvesting calls back into `harvest_payees`.
//! - Payouts never need the recipient's signature: anyone can pay booked fees to their rightful owner (P10).

use crate::admin::{check_window, require_admin};
use crate::events::{
    CreatorFeesClaimed, CreatorFeesOwed, OwedClaimed, RecipientChangeCancelled, RecipientProposed, RecipientSet,
};
use crate::storage::{
    config, creator_owed, load_curve, load_launch, recipient, save_curve, set_creator_owed, set_recipient,
    set_temporary, takeover, DataKey, Takeover,
};
use crate::{Error, DAY_SECS};
use soroban_sdk::{panic_with_error, token::TokenClient, Address, Env};

/// The current recipient hands the role to `new`.
pub(crate) fn transfer(e: &Env, token: &Address, new: Address) {
    recipient(e, token).require_auth();
    change(e, token, new, false);
}

/// The admin proposes a takeover of `token`'s recipient.
pub(crate) fn propose(e: &Env, token: &Address, new: Address) {
    let cfg = require_admin(e);
    load_launch(e, token);
    let now = e.ledger().timestamp();
    let effective_at = now + cfg.durations.takeover_delay;
    let expires_at = effective_at + cfg.durations.takeover_window;
    let t = Takeover { new: new.clone(), effective_at, expires_at };
    // It disappears a day after it expires, which is what a stale proposal should do.
    set_temporary(e, &DataKey::Takeover(token.clone()), &t, expires_at - now + DAY_SECS);
    RecipientProposed { token: token.clone(), new, effective_at, expires_at }.publish(e);
}

/// The admin, or the current recipient (its veto), drops a pending takeover.
pub(crate) fn cancel(e: &Env, token: &Address, caller: Address) {
    if caller != config(e).admin && caller != recipient(e, token) {
        panic_with_error!(e, Error::NotAuthorized);
    }
    caller.require_auth();
    if takeover(e, token).is_none() {
        panic_with_error!(e, Error::NoProposal);
    }
    e.storage().temporary().remove(&DataKey::Takeover(token.clone()));
    RecipientChangeCancelled { token: token.clone(), by: caller }.publish(e);
}

/// Anyone, inside the window.
pub(crate) fn execute(e: &Env, token: &Address) {
    let t = takeover(e, token).unwrap_or_else(|| panic_with_error!(e, Error::NoProposal));
    check_window(e, t.effective_at, t.expires_at);
    e.storage().temporary().remove(&DataKey::Takeover(token.clone()));
    change(e, token, t.new, true);
}

/// Pays the booked creator fees to the current recipient.
pub(crate) fn claim_creator_fees(e: &Env, token: &Address) -> i128 {
    let launch = load_launch(e, token);
    let mut curve = load_curve(e, token);
    let amount = curve.creator_fees;
    if amount <= 0 {
        panic_with_error!(e, Error::NothingToClaim);
    }
    curve.creator_fees = 0;
    save_curve(e, token, &curve);
    let to = recipient(e, token);
    TokenClient::new(e, &launch.quote).transfer(&e.current_contract_address(), &to, &amount);
    CreatorFeesClaimed { token: token.clone(), recipient: to, amount }.publish(e);
    amount
}

/// Pays what a recipient change left owed to `account` in `asset`.
pub(crate) fn claim_owed(e: &Env, account: &Address, asset: &Address) -> i128 {
    let amount = creator_owed(e, account, asset);
    if amount <= 0 {
        panic_with_error!(e, Error::NothingToClaim);
    }
    set_creator_owed(e, account, asset, 0);
    TokenClient::new(e, asset).transfer(&e.current_contract_address(), account, &amount);
    OwedClaimed { account: account.clone(), asset: asset.clone(), amount }.publish(e);
    amount
}

/// The change itself (L14): the fees booked so far stay with the old recipient.
fn change(e: &Env, token: &Address, new: Address, by_takeover: bool) {
    let launch = load_launch(e, token);
    let old = recipient(e, token);
    let mut curve = load_curve(e, token);
    if curve.creator_fees > 0 {
        let amount = curve.creator_fees;
        set_creator_owed(e, &old, &launch.quote, creator_owed(e, &old, &launch.quote) + amount);
        curve.creator_fees = 0;
        save_curve(e, token, &curve);
        CreatorFeesOwed { token: token.clone(), old_recipient: old.clone(), amount }.publish(e);
    }
    set_recipient(e, token, &new);
    RecipientSet { token: token.clone(), old, new, by_takeover }.publish(e);
}
