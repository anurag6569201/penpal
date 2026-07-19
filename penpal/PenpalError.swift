//
//  PenpalError.swift
//  penpal
//
//  PEN-13 — errors in the product's voice.
//
//  The app used to surface `error.localizedDescription` straight into an
//  alert, so a dropped wifi connection said:
//
//      The operation couldn’t be completed. (NSURLErrorDomain error -1009.)
//
//  That sentence tells the user three things, all of them wrong: that they
//  did something, that Penpal is software rather than paper, and — worst —
//  it says nothing about whether their handwriting survived. On a writing
//  surface the first question after any failure is "did I lose my work?",
//  and every message here answers it.
//
//  Rules for this file:
//    * Say what happened, in words a person would use.
//    * Say whether their work is safe, whenever it is.
//    * Say what happens next, or what they can do — one thing, not three.
//    * Never blame the user. Never show an error code.
//    * Stay short. This is read on a page, mid-thought.
//

import Foundation

enum PenpalError {

    /// Turns anything thrown by the API layer into something worth reading.
    static func message(for error: Error) -> String {
        if let apiError = error as? PenpalAPI.APIError {
            return message(for: apiError)
        }
        return message(forURLError: error as NSError)
    }

    // MARK: - API errors

    private static func message(for error: PenpalAPI.APIError) -> String {
        switch error {
        case .badURL:
            return "That brain address doesn't look right. Check it in Settings → Behavior."

        case .emptyReply:
            return "I drew a blank on that one — try asking again."

        case .transport(let underlying):
            return message(forURLError: underlying as NSError)

        case .http(let code, let body):
            return message(forStatus: code, body: body)
        }
    }

    private static func message(forStatus code: Int, body: String) -> String {
        switch code {
        case 401, 403:
            return "My brain didn't recognise this device. Add the access token in Settings → Behavior."
        case 429:
            // Rate limited (PEN-26). Not an error the user caused — a pace.
            return "We're going a bit fast for my brain. Give it a minute and I'll pick this up again."
        case 500...599:
            return "My brain is having a moment. Your work is safe — try again shortly."
        case 400...499:
            // The server's own message is written for a person (chat/views.py),
            // so prefer it when there is one.
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "I couldn't make sense of that one." : detail
        default:
            return "Something went wrong reaching my brain. Your work is safe."
        }
    }

    // MARK: - Network errors

    private static func message(forURLError error: NSError) -> String {
        guard error.domain == NSURLErrorDomain else {
            return "Something went wrong. Your work is safe on the page."
        }
        switch error.code {
        case NSURLErrorNotConnectedToInternet:
            return "No connection right now. I've kept this — I'll answer as soon as we're back."
        case NSURLErrorTimedOut:
            return "My brain took too long to answer. I've kept your work; try again when you like."
        case NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed:
            return "I can't reach my brain at that address. Is it running? Check Settings → Behavior."
        case NSURLErrorNetworkConnectionLost:
            return "The connection dropped mid-thought. I've kept this and I'll try again."
        case NSURLErrorCancelled:
            return ""   // The user did this on purpose; say nothing.
        default:
            return "I couldn't reach my brain just now. Your work is safe on the page."
        }
    }

    // MARK: - Classification

    /// Worth retrying automatically? Connectivity and server hiccups are;
    /// a bad address or a rejected token will fail identically forever, and
    /// retrying those just burns battery and quota.
    static func isTransient(_ error: Error) -> Bool {
        if let apiError = error as? PenpalAPI.APIError {
            switch apiError {
            case .badURL:
                return false
            case .emptyReply:
                return false
            case .http(let code, _):
                return code == 429 || (500...599).contains(code)
            case .transport(let underlying):
                return isTransient(underlying)
            }
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorNotConnectedToInternet,
                NSURLErrorTimedOut,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorDNSLookupFailed,
                NSURLErrorCannotFindHost].contains(nsError.code)
    }

    /// True when the failure is purely a lost connection, as opposed to the
    /// brain being reachable but unhappy. Only these are worth queueing —
    /// a 500 will probably still be a 500 in ten minutes.
    static func isOffline(_ error: Error) -> Bool {
        if let apiError = error as? PenpalAPI.APIError,
           case .transport(let underlying) = apiError {
            return isOffline(underlying)
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorNotConnectedToInternet,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorCannotConnectToHost].contains(nsError.code)
    }
}
