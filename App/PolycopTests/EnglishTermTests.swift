// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

@Test func filtersEnglishStopWordsAndSlideFurnitureOnMultiPageSlides() async {
    let slides = [
        """
        LECTURE 1: SLIDE OVERVIEW AND SUMMARY
        The Turing Machine formalises computation. This model follows Chomsky.
        However, Bayesian Inference handles uncertainty. Therefore, RNA and CRISPR-Cas9 matter.
        Although fMRI measures cortical activity, NATO coordinates standards.
        Between sessions, review the chapter. During seminars, compare results.
        Lecture 1, Slide 1, Chapter 1, Summary, Overview, References, University of Oxford.
        """,
        """
        CHAPTER 2: UNIVERSITY REFERENCES
        The hierarchy proposed by Chomsky complements the Turing Machine.
        This step applies Bayesian Inference to CRISPR-Cas9 and RNA data.
        These readings use fMRI protocols approved with NATO partners.
        However, the bound holds. Therefore, convergence follows.
        Although noise remains, the signal is clear.
        Between trials, calibrate the scanner. During testing, record latencies.
        These conclusions close Lecture 2, Slide 2, Chapter 2, Summary, Overview, References, University.
        """,
    ]

    let terms = await Terms.candidates(in: slides)

    for kept in [
        "Chomsky", "Turing Machine", "Bayesian Inference", "CRISPR-Cas9", "fMRI", "RNA", "NATO",
    ] {
        #expect(terms.contains(kept))
    }
    for stopWord in [
        "The", "This", "These", "However", "Therefore", "Although", "Between", "During",
        "Lecture", "Slide", "Chapter", "Summary", "Overview", "References", "University",
        "LECTURE", "SLIDE", "CHAPTER", "SUMMARY", "OVERVIEW", "REFERENCES", "UNIVERSITY",
        "The Turing Machine", "CRISPR-Cas",
    ] {
        #expect(!terms.contains(stopWord))
    }
}

@Test func keepsTermsAndFiltersStopWordsInBilingualCourseMaterial() async {
    let slides = [
        """
        COURS ET SLIDE 1: OVERVIEW
        Cependant, Chomsky et Jean Piaget sont cités. The Turing Machine est présentée.
        However, Bayesian Inference et CRISPR-Cas9 complètent l'analyse par fMRI de l'RNA.
        During the seminar, Robert May et NATO sont mentionnés.
        """,
        """
        CHAPITRE 2: SUMMARY AND REFERENCES
        Toutefois, Chomsky et Jean Piaget reviennent. This section covers Bayesian Inference.
        Therefore, the Turing Machine, CRISPR-Cas9, fMRI, RNA, and NATO remain central.
        Between lectures, relire Robert May.
        """,
    ]

    let terms = await Terms.candidates(in: slides)

    for kept in [
        "Chomsky", "Jean Piaget", "Turing Machine", "Bayesian Inference",
        "CRISPR-Cas9", "fMRI", "RNA", "NATO", "Robert May",
    ] {
        #expect(terms.contains(kept))
    }
    for excluded in [
        "Cependant", "Toutefois", "The", "This", "However", "Therefore", "During", "Between",
        "COURS", "SLIDE", "OVERVIEW", "CHAPITRE", "SUMMARY", "REFERENCES",
    ] {
        #expect(!terms.contains(excluded))
    }
}
